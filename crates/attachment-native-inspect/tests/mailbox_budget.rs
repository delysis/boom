use attachment_native_inspect::{Inspector, ProvidedAttachment};
use attachment_native_types::{AttachmentBundle, BudgetLimits, Coverage, InspectionPolicy};

fn inspect(messages: usize, entries: u32, edges: u32) -> AttachmentBundle {
    let message = b"From sender@example.com Sat Jan 1 00:00:00 2022\nFrom: sender@example.com\nTo: reader@example.com\nSubject: Budget fixture\n\nAuthored body.\n";
    Inspector::new(InspectionPolicy {
        limits: BudgetLimits {
            max_entries: entries,
            max_edges: edges,
            ..BudgetLimits::default()
        },
        ..InspectionPolicy::default()
    })
    .expect("valid mailbox policy")
    .inspect(ProvidedAttachment::from_bytes(
        "fixture.mbox",
        Some("application/mbox".into()),
        message.repeat(messages),
    ))
    .expect("mailbox inspection returns an explicit graph")
}

#[test]
fn mailbox_at_the_remaining_limit_is_admitted() {
    let bundle = inspect(1, 1, 1);
    assert_eq!(bundle.graph.coverage, Coverage::Complete);
    assert_eq!(bundle.graph.edges.len(), 1);
    assert_eq!(bundle.graph.usage.entries, 1);
    assert_eq!(bundle.graph.usage.edges, 1);
}

#[test]
fn either_mailbox_limit_rejects_before_any_message_is_retained() {
    for (entries, edges) in [(1, 8), (8, 1)] {
        for messages in [2, 10_000] {
            let bundle = inspect(messages, entries, edges);
            assert_ne!(bundle.graph.coverage, Coverage::Complete);
            assert_eq!(bundle.graph.objects.len(), 1);
            assert!(bundle.graph.edges.is_empty());
            assert_eq!(bundle.graph.usage.entries, 0);
            assert_eq!(bundle.graph.usage.edges, 0);
            assert_eq!(bundle.graph.usage.total_derived_bytes, 0);
            assert!(
                bundle
                    .graph
                    .issues
                    .iter()
                    .any(|issue| issue.code == "mbox_entry_limit")
            );
        }
    }
}
