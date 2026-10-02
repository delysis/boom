use attachment_native_types::{AttachmentError, BudgetLimits, BudgetUsage};
use std::time::{Duration, Instant};

pub(crate) struct BudgetLedger {
    limits: BudgetLimits,
    usage: BudgetUsage,
    started: Instant,
}

impl BudgetLedger {
    pub(crate) fn new(limits: BudgetLimits) -> Self {
        Self {
            limits,
            usage: BudgetUsage::default(),
            started: Instant::now(),
        }
    }

    pub(crate) fn finish(self) -> BudgetUsage {
        self.usage
    }

    pub(crate) fn check_deadline(&self) -> Result<(), AttachmentError> {
        if self.started.elapsed() > Duration::from_millis(self.limits.deadline_ms) {
            return Err(AttachmentError::budget(
                "attachment_deadline_exceeded",
                "Attachment inspection exceeded its configured deadline.",
            ));
        }
        Ok(())
    }

    pub(crate) fn charge_root(&mut self, bytes: u64) -> Result<(), AttachmentError> {
        self.check_deadline()?;
        if bytes > self.limits.max_root_bytes {
            return Err(AttachmentError::budget(
                "root_bytes_exceeded",
                format!(
                    "The attachment is {bytes} bytes; the configured root limit is {} bytes.",
                    self.limits.max_root_bytes
                ),
            ));
        }
        let root_bytes = checked_add(self.usage.root_bytes, bytes)?;
        let retained_bytes = self.next_retained_bytes(bytes)?;
        let objects = self.next_object_count()?;
        self.usage.root_bytes = root_bytes;
        self.usage.retained_bytes = retained_bytes;
        self.usage.objects = objects;
        Ok(())
    }

    pub(crate) fn charge_entry(&mut self) -> Result<(), AttachmentError> {
        self.check_deadline()?;
        let next = self
            .usage
            .entries
            .checked_add(1)
            .ok_or_else(integer_overflow)?;
        if next > self.limits.max_entries {
            return Err(AttachmentError::budget(
                "archive_entry_limit_exceeded",
                format!(
                    "Attachment containers exceed the configured {} entry limit.",
                    self.limits.max_entries
                ),
            ));
        }
        self.usage.entries = next;
        Ok(())
    }

    pub(crate) fn remaining_entries(&self) -> u32 {
        self.limits.max_entries.saturating_sub(self.usage.entries)
    }

    pub(crate) fn remaining_objects(&self) -> u32 {
        self.limits.max_objects.saturating_sub(self.usage.objects)
    }

    pub(crate) fn remaining_edges(&self) -> u32 {
        self.limits.max_edges.saturating_sub(self.usage.edges)
    }

    pub(crate) fn remaining_derived_bytes(&self) -> u64 {
        self.limits
            .max_total_derived_bytes
            .saturating_sub(self.usage.total_derived_bytes)
    }

    pub(crate) fn derived_budget_exhausted(&self) -> bool {
        self.remaining_derived_bytes() == 0
    }

    pub(crate) fn charge_edge(&mut self, depth: u16) -> Result<(), AttachmentError> {
        self.check_deadline()?;
        let next = self
            .usage
            .edges
            .checked_add(1)
            .ok_or_else(integer_overflow)?;
        if next > self.limits.max_edges {
            return Err(AttachmentError::budget(
                "derivation_edge_limit_exceeded",
                format!(
                    "Attachment expansion exceeds the configured {} edge limit.",
                    self.limits.max_edges
                ),
            ));
        }
        self.usage.edges = next;
        self.usage.deepest_object = self.usage.deepest_object.max(depth);
        Ok(())
    }

    pub(crate) fn depth_allows_derivation(&self, child_depth: u16) -> bool {
        child_depth <= self.limits.max_depth
    }

    pub(crate) fn check_name_len(&self, bytes: usize) -> Result<(), AttachmentError> {
        let bytes = u32::try_from(bytes).map_err(|_| integer_overflow())?;
        if bytes > self.limits.max_name_bytes {
            return Err(AttachmentError::budget(
                "archive_name_limit_exceeded",
                format!(
                    "An archive member name is {bytes} bytes; the configured limit is {} bytes.",
                    self.limits.max_name_bytes
                ),
            ));
        }
        Ok(())
    }

    pub(crate) fn check_declared_member(
        &self,
        declared: u64,
        compressed: Option<u64>,
    ) -> Result<(), AttachmentError> {
        if declared > self.limits.max_object_bytes {
            return Err(AttachmentError::budget(
                "object_bytes_exceeded",
                format!(
                    "An attachment member declares {declared} bytes; the configured object limit is {} bytes.",
                    self.limits.max_object_bytes
                ),
            ));
        }
        if let Some(compressed) = compressed
            && declared > 0
        {
            let base = compressed.max(1);
            let allowed = base
                .checked_mul(u64::from(self.limits.max_declared_to_actual_ratio))
                .ok_or_else(integer_overflow)?;
            if declared > allowed {
                return Err(AttachmentError::budget(
                    "compression_ratio_exceeded",
                    format!(
                        "An attachment member declares an expansion ratio above the configured {}:1 limit.",
                        self.limits.max_declared_to_actual_ratio
                    ),
                ));
            }
        }
        Ok(())
    }

    pub(crate) fn max_stream_output(&self, compressed: Option<u64>) -> u64 {
        let ratio_bound = compressed.and_then(|bytes| {
            bytes
                .max(1)
                .checked_mul(u64::from(self.limits.max_declared_to_actual_ratio))
        });
        let remaining = self
            .limits
            .max_total_derived_bytes
            .saturating_sub(self.usage.total_derived_bytes);
        self.limits
            .max_object_bytes
            .min(remaining)
            .min(ratio_bound.unwrap_or(u64::MAX))
    }

    pub(crate) fn charge_derived_chunk(&mut self, bytes: usize) -> Result<(), AttachmentError> {
        self.check_deadline()?;
        let bytes = u64::try_from(bytes).map_err(|_| integer_overflow())?;
        let next = checked_add(self.usage.total_derived_bytes, bytes)?;
        if next > self.limits.max_total_derived_bytes {
            // The caller has already received this decoded chunk. Charge the
            // remaining allowance before rejecting it so a decoder cannot
            // repeatedly cross the boundary without consuming the global
            // work budget.
            self.usage.total_derived_bytes = self.limits.max_total_derived_bytes;
            return Err(AttachmentError::budget(
                "total_derived_bytes_exceeded",
                format!(
                    "Attachment expansion exceeds the configured {} byte cumulative limit.",
                    self.limits.max_total_derived_bytes
                ),
            ));
        }
        self.usage.total_derived_bytes = next;
        Ok(())
    }

    pub(crate) fn charge_rejected_stream_attempt(&mut self, attempted: u64) {
        let charge = attempted.min(self.remaining_derived_bytes());
        self.usage.total_derived_bytes = self.usage.total_derived_bytes.saturating_add(charge);
    }

    pub(crate) fn charge_unique_object(
        &mut self,
        bytes: u64,
        depth: u16,
    ) -> Result<(), AttachmentError> {
        self.check_deadline()?;
        let retained_bytes = self.next_retained_bytes(bytes)?;
        let objects = self.next_object_count()?;
        self.usage.retained_bytes = retained_bytes;
        self.usage.objects = objects;
        self.usage.deepest_object = self.usage.deepest_object.max(depth);
        Ok(())
    }

    fn next_retained_bytes(&self, bytes: u64) -> Result<u64, AttachmentError> {
        let next = checked_add(self.usage.retained_bytes, bytes)?;
        if next > self.limits.max_retained_bytes {
            return Err(AttachmentError::budget(
                "retained_bytes_exceeded",
                format!(
                    "Attachment inspection exceeds the configured {} byte retained-data limit.",
                    self.limits.max_retained_bytes
                ),
            ));
        }
        Ok(next)
    }

    fn next_object_count(&self) -> Result<u32, AttachmentError> {
        let next = self
            .usage
            .objects
            .checked_add(1)
            .ok_or_else(integer_overflow)?;
        if next > self.limits.max_objects {
            return Err(AttachmentError::budget(
                "object_count_exceeded",
                format!(
                    "Attachment inspection exceeds the configured {} object limit.",
                    self.limits.max_objects
                ),
            ));
        }
        Ok(next)
    }
}

fn checked_add(left: u64, right: u64) -> Result<u64, AttachmentError> {
    left.checked_add(right).ok_or_else(integer_overflow)
}

fn integer_overflow() -> AttachmentError {
    AttachmentError::budget(
        "budget_integer_overflow",
        "Attachment budget accounting overflowed and the operation was blocked.",
    )
}

#[cfg(test)]
mod tests {
    use super::BudgetLedger;
    use attachment_native_types::{BudgetLimits, BudgetUsage};

    #[test]
    fn unique_object_reservation_is_atomic_when_object_count_is_exhausted() {
        let limits = BudgetLimits {
            max_objects: 1,
            ..BudgetLimits::default()
        };
        let mut budget = BudgetLedger::new(limits);
        budget.charge_root(7).expect("root reservation");
        let error = budget
            .charge_unique_object(11, 1)
            .expect_err("second object must be rejected");
        assert_eq!(error.code, "object_count_exceeded");
        let usage = budget.finish();
        assert_eq!(usage.objects, 1);
        assert_eq!(usage.retained_bytes, 7);
        assert_eq!(usage.deepest_object, 0);
    }

    #[test]
    fn every_successful_charge_is_monotonic_and_limits_are_independent() {
        let limits = BudgetLimits {
            max_depth: 1,
            max_edges: 3,
            ..BudgetLimits::default()
        };
        let mut budget = BudgetLedger::new(limits);
        let mut earlier = BudgetUsage::default();

        budget.charge_root(7).expect("root");
        assert!(budget.usage.dominates(&earlier));
        earlier = budget.usage.clone();
        budget.charge_entry().expect("entry");
        assert!(budget.usage.dominates(&earlier));
        earlier = budget.usage.clone();
        budget.charge_derived_chunk(5).expect("derived bytes");
        assert!(budget.usage.dominates(&earlier));
        earlier = budget.usage.clone();
        budget.charge_edge(1).expect("edge at depth bound");
        assert!(budget.usage.dominates(&earlier));
        assert!(!budget.depth_allows_derivation(2));
        assert_eq!(budget.remaining_edges(), 2);
    }

    #[test]
    fn attempted_derived_work_is_charged_without_overflow_or_wraparound() {
        let limits = BudgetLimits {
            max_total_derived_bytes: 4,
            max_object_bytes: 4,
            ..BudgetLimits::default()
        };
        let mut budget = BudgetLedger::new(limits);
        budget.charge_rejected_stream_attempt(u64::MAX);
        assert_eq!(budget.usage.total_derived_bytes, 4);
        budget.charge_rejected_stream_attempt(u64::MAX);
        assert_eq!(budget.usage.total_derived_bytes, 4);

        budget.usage.total_derived_bytes = u64::MAX;
        let error = budget
            .charge_derived_chunk(1)
            .expect_err("checked accounting cannot wrap");
        assert_eq!(error.code, "budget_integer_overflow");
        assert_eq!(budget.usage.total_derived_bytes, u64::MAX);
    }
}
