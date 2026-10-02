//! Mailbox members use the same monotonic budget as archive and MIME members.
use super::*;
use mail_parser::mailbox::mbox::MessageIterator;

impl InspectionState {
    pub(super) fn expand_mbox(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        // Count before parsing: do not allocate an attacker-selected subset of
        // a mailbox which cannot fit the remaining entry/edge budget.
        let count = bytes
            .split(|b| *b == b'\n')
            .filter(|line| line.starts_with(b"From "))
            .count();
        if count == 0
            || count > self.budget.remaining_entries() as usize
            || count > self.budget.remaining_edges() as usize
        {
            self.issue(
                "mbox_entry_limit",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The mailbox exceeds the remaining message budget.",
                true,
            );
            return;
        }
        for (index, message) in MessageIterator::new(Cursor::new(bytes)).enumerate() {
            if let Err(error) = self.budget.charge_entry() {
                self.record_budget_issue(parent, &error);
                break;
            }
            let message = match message {
                Ok(message) => message,
                Err(_) => {
                    self.issue(
                        "mbox_parse_failed",
                        IssueClass::Malformed,
                        IssueSeverity::Blocked,
                        Some(parent.clone()),
                        "The mailbox could not be read completely.",
                        true,
                    );
                    break;
                }
            };
            let contents = message.contents();
            let child_depth = depth.saturating_add(1);
            if let Err(error) = self.budget.charge_edge(child_depth) {
                self.record_budget_issue(parent, &error);
                break;
            }
            let name = format!("message-{}.eml", index + 1);
            let Ok(name) = logical_member_name(
                name.as_bytes(),
                index,
                self.policy.limits.max_name_bytes,
                self.policy.path_policy,
            ) else {
                self.issue(
                    "mbox_name_limit",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The mailbox member name exceeds the name budget.",
                    true,
                );
                break;
            };
            let mut edge = DerivationEdge {
                parent: parent.clone(),
                child: None,
                depth: child_depth,
                name: name.logical,
                transform: provenance(TransformKind::MailboxMessage),
                declared_uncompressed_bytes: Some(contents.len() as u64),
                compressed_bytes: None,
                source_range: None,
                outcome: EdgeOutcome::Malformed,
            };
            if !self.budget.depth_allows_derivation(child_depth) {
                edge.outcome = EdgeOutcome::DepthExceeded;
                self.edges.push(edge);
                self.issue(
                    "attachment_depth_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The mailbox message exceeds the derivation depth limit.",
                    true,
                );
                continue;
            }
            if let Err(error) = self
                .budget
                .check_declared_member(contents.len() as u64, None)
                .and_then(|()| self.budget.charge_derived_chunk(contents.len()))
            {
                edge.outcome = EdgeOutcome::BudgetExceeded;
                self.edges.push(edge);
                self.record_budget_issue(parent, &error);
                continue;
            }
            // A broken member must not become an apparently valid text import.
            if !super::detect::looks_like_email_bytes(contents) {
                self.edges.push(edge);
                self.issue(
                    "mbox_message_invalid",
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "A mailbox member does not contain recognizable email headers.",
                    true,
                );
                continue;
            }
            if let Err(error) = self.finish_child(edge, contents.to_vec(), Some("message/rfc822")) {
                self.record_budget_issue(parent, &error);
            }
        }
    }
}
