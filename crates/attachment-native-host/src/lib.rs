#![forbid(unsafe_code)]

//! Immutable attachment processing host.
//!
//! The host composes inspection, canonicalization, and capability planning. It
//! owns policy but no ambient authority: input bytes are caller-granted and
//! persistence, transforms, speech, model execution, networking, and UI remain
//! the embedding application's responsibility.

use attachment_native_document::{CanonicalizationSummary, DocumentCanonicalizer, DocumentLimits};
use attachment_native_inspect::Inspector;
pub use attachment_native_inspect::ProvidedAttachment;
use attachment_native_plan::PreparationPlanner;
use attachment_native_types::{
    AttachmentBundle, AttachmentError, AttachmentReceipt, Coverage, InspectionPolicy,
    PreparationPlan, PreparationPolicy, RECEIPT_SCHEMA, ReceiptStatus, TargetCapabilities,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::time::{Duration, Instant};

const HOST_PROCESSOR: &str = "attachment-native-host";
const HOST_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct AttachmentHostConfig {
    pub inspection: InspectionPolicy,
    pub documents: DocumentLimits,
    pub preparation: PreparationPolicy,
}

#[derive(Debug, Clone)]
pub struct CanonicalizedAttachment {
    pub bundle: AttachmentBundle,
    pub canonicalization: CanonicalizationSummary,
    pub receipt: AttachmentReceipt,
}

#[derive(Debug, Clone)]
pub struct PreparedAttachment {
    pub bundle: AttachmentBundle,
    pub canonicalization: CanonicalizationSummary,
    pub plan: PreparationPlan,
    pub receipt: AttachmentReceipt,
}

#[derive(Debug, Clone)]
pub struct AttachmentHost {
    inspector: Inspector,
    canonicalizer: DocumentCanonicalizer,
    planner: PreparationPlanner,
    preparation: PreparationPolicy,
    policy_fingerprint: String,
    job_deadline: Duration,
}

impl AttachmentHost {
    pub fn new(config: AttachmentHostConfig) -> Result<Self, AttachmentError> {
        let policy_fingerprint = policy_fingerprint(&config)?;
        let job_deadline = Duration::from_millis(config.inspection.limits.deadline_ms);
        Ok(Self {
            inspector: Inspector::new(config.inspection)?,
            canonicalizer: DocumentCanonicalizer::new(config.documents)?,
            planner: PreparationPlanner::new(),
            preparation: config.preparation,
            policy_fingerprint,
            job_deadline,
        })
    }

    #[must_use]
    pub fn policy_fingerprint(&self) -> &str {
        &self.policy_fingerprint
    }

    pub fn inspect_and_canonicalize(
        &self,
        input: ProvidedAttachment,
    ) -> Result<CanonicalizedAttachment, AttachmentError> {
        self.inspect_and_canonicalize_started(input, Instant::now())
    }

    fn inspect_and_canonicalize_started(
        &self,
        input: ProvidedAttachment,
        started: Instant,
    ) -> Result<CanonicalizedAttachment, AttachmentError> {
        let deadline = started.checked_add(self.job_deadline).unwrap_or(started);
        let mut bundle = self.inspector.inspect(input)?;
        let canonicalization = self.canonicalizer.canonicalize_until(
            &mut bundle,
            &self.policy_fingerprint,
            deadline,
        )?;
        bundle.validate().map_err(contract_error)?;
        let receipt = receipt_for(&bundle, &self.policy_fingerprint, None)?;
        Ok(CanonicalizedAttachment {
            bundle,
            canonicalization,
            receipt,
        })
    }

    pub fn prepare(
        &self,
        bundle: &AttachmentBundle,
        target: &TargetCapabilities,
    ) -> Result<PreparationPlan, AttachmentError> {
        bundle.validate().map_err(contract_error)?;
        let plan = self.planner.plan(bundle, target, &self.preparation)?;
        plan.validate_against(bundle).map_err(contract_error)?;
        Ok(plan)
    }

    pub fn process(
        &self,
        input: ProvidedAttachment,
        target: &TargetCapabilities,
    ) -> Result<PreparedAttachment, AttachmentError> {
        let canonicalized = self.inspect_and_canonicalize(input)?;
        let plan = self.prepare(&canonicalized.bundle, target)?;
        let receipt = receipt_for(&canonicalized.bundle, &self.policy_fingerprint, Some(&plan))?;
        Ok(PreparedAttachment {
            bundle: canonicalized.bundle,
            canonicalization: canonicalized.canonicalization,
            plan,
            receipt,
        })
    }
}

fn policy_fingerprint(config: &AttachmentHostConfig) -> Result<String, AttachmentError> {
    let encoded = serde_json::to_vec(config).map_err(|error| {
        AttachmentError::blocked(
            "attachment_policy_encode_failed",
            format!("The attachment policy could not be encoded deterministically: {error}"),
        )
    })?;
    Ok(format!("sha256:{:x}", Sha256::digest(encoded)))
}

fn receipt_for(
    bundle: &AttachmentBundle,
    policy_fingerprint: &str,
    plan: Option<&PreparationPlan>,
) -> Result<AttachmentReceipt, AttachmentError> {
    let partial = !matches!(bundle.graph.coverage, Coverage::Complete);
    let blocked = plan.is_some_and(|plan| !plan.blockers.is_empty());
    let status = if blocked
        && plan.is_some_and(|plan| plan.parts.is_empty() && plan.transforms.is_empty())
    {
        ReceiptStatus::Blocked
    } else if blocked || partial {
        ReceiptStatus::Partial
    } else {
        ReceiptStatus::Passed
    };
    let receipt = AttachmentReceipt {
        schema: RECEIPT_SCHEMA.to_string(),
        job_id: bundle.graph.job_id.clone(),
        status,
        root_sha256: bundle.graph.root.0.clone(),
        policy_fingerprint: policy_fingerprint.to_string(),
        processor_versions: BTreeMap::from([
            (HOST_PROCESSOR.to_string(), HOST_VERSION.to_string()),
            (
                "attachment-native-inspect".to_string(),
                env!("CARGO_PKG_VERSION").to_string(),
            ),
            (
                "attachment-native-document".to_string(),
                env!("CARGO_PKG_VERSION").to_string(),
            ),
            (
                "attachment-native-plan".to_string(),
                env!("CARGO_PKG_VERSION").to_string(),
            ),
        ]),
        usage: bundle.graph.usage.clone(),
        complete_coverage: !partial,
        network_used: false,
        process_used: false,
        model_invoked: false,
        changed_paths: Vec::new(),
    };
    receipt
        .validate_against(bundle, plan)
        .map_err(contract_error)?;
    Ok(receipt)
}

fn contract_error(error: impl ToString) -> AttachmentError {
    AttachmentError {
        code: "attachment_contract_invalid".to_string(),
        class: attachment_native_types::IssueClass::Internal,
        safe_message: error.to_string(),
        object_id: None,
        retryable: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use attachment_native_types::{ArtifactPayload, ContractError, TextFormat};

    #[test]
    fn complete_text_pipeline_is_authority_free_and_deterministic() -> Result<(), AttachmentError> {
        let host = AttachmentHost::new(AttachmentHostConfig::default())
            .expect("built-in policy must be valid");
        let target = TargetCapabilities {
            target_id: "fixture-text-model".to_string(),
            fingerprint: "fixture:v1".to_string(),
            accepted_media_types: Default::default(),
            accepted_media_families: Default::default(),
            max_media_objects: 1,
            max_media_bytes: 1024,
            max_text_bytes: 1024,
            supports_markdown: true,
            supports_native_pdf: false,
            supports_native_video: false,
        };
        let first = host
            .process(
                ProvidedAttachment::from_bytes(
                    "note.md",
                    Some("text/markdown".to_string()),
                    b"# Safe\n\nattachment text".to_vec(),
                ),
                &target,
            )
            .expect("fixture must process");
        let second = host
            .process(
                ProvidedAttachment::from_bytes(
                    "note.md",
                    Some("text/markdown".to_string()),
                    b"# Safe\n\nattachment text".to_vec(),
                ),
                &target,
            )
            .expect("fixture must process twice");

        assert_eq!(first.bundle.graph.root, second.bundle.graph.root);
        assert_eq!(first.plan.cache_fingerprint, second.plan.cache_fingerprint);
        assert_eq!(first.receipt.status, ReceiptStatus::Passed);
        assert!(!first.receipt.network_used);
        assert!(!first.receipt.process_used);
        assert!(!first.receipt.model_invoked);
        assert!(first.plan.parts.iter().any(|part| matches!(
            part,
            attachment_native_types::PreparedPart::UntrustedText {
                format: TextFormat::Markdown,
                ..
            }
        )));
        assert!(
            first
                .bundle
                .artifacts
                .iter()
                .any(|artifact| matches!(artifact.payload, ArtifactPayload::Text { .. }))
        );

        let mut forged_graph = first.bundle.graph.clone();
        forged_graph.usage.objects = 0;
        assert!(matches!(
            forged_graph.validate(),
            Err(ContractError::InvalidGraph(_))
        ));

        let mut missing_blob = first.bundle.clone();
        missing_blob.blobs.clear();
        assert!(matches!(
            missing_blob.validate(),
            Err(ContractError::MissingBlob(_))
        ));

        let mut forged_receipt = first.receipt.clone();
        forged_receipt.complete_coverage = false;
        assert!(matches!(
            forged_receipt.validate_against(&first.bundle, Some(&first.plan)),
            Err(ContractError::InvalidReceipt(_))
        ));

        let mut forged_plan = first.plan.clone();
        let text = forged_plan
            .parts
            .iter_mut()
            .find_map(|part| match part {
                attachment_native_types::PreparedPart::UntrustedText { text, .. } => Some(text),
                _ => None,
            })
            .ok_or_else(|| {
                AttachmentError::blocked(
                    "fixture_text_missing",
                    "The fixture plan must contain text.",
                )
            })?;
        text.push_str(" substituted");
        assert!(matches!(
            forged_plan.validate_against(&first.bundle),
            Err(ContractError::InvalidPreparationPlan(message))
                if message.contains("does not match its canonical artifact")
        ));
        assert!(matches!(
            first
                .receipt
                .validate_against(&first.bundle, Some(&forged_plan)),
            Err(ContractError::InvalidPreparationPlan(_))
        ));
        Ok(())
    }

    #[test]
    fn canonicalization_uses_the_original_host_job_deadline() {
        let host = AttachmentHost::new(AttachmentHostConfig::default())
            .expect("built-in policy must be valid");
        let started = Instant::now()
            .checked_sub(host.job_deadline + Duration::from_millis(1))
            .expect("the monotonic clock must represent the recent past");
        let result = host
            .inspect_and_canonicalize_started(
                ProvidedAttachment::from_bytes(
                    "expired.txt",
                    Some("text/plain".to_string()),
                    b"must not reach document parsing".to_vec(),
                ),
                started,
            )
            .expect("deadline exhaustion is a typed partial result");

        assert!(result.bundle.artifacts.is_empty());
        assert!(result.bundle.graph.issues.iter().any(|issue| {
            issue.code == "canonical_processing_deadline_exceeded"
                && issue.class == attachment_native_types::IssueClass::Budget
        }));
        assert_eq!(result.receipt.status, ReceiptStatus::Partial);
    }
}
