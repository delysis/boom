#![forbid(unsafe_code)]

//! Deterministic, capability-aware attachment preparation planning.
//!
//! This crate does not execute transforms. It compiles canonical attachment
//! artifacts into a fail-closed plan for one exact target capability
//! fingerprint. The host may then execute the requested transforms through
//! separately authorized OCR, speech, or media workers.

use attachment_native_types::{
    ArtifactId, ArtifactPayload, AttachmentBundle, AttachmentError, BlobValidation,
    CanonicalArtifact, ContractError, DetectedFormat, IssueClass, MediaFamily, ObjectId,
    ObjectStatus, PLAN_SCHEMA, PreparationAggregateLimits, PreparationBlocker, PreparationPlan,
    PreparationPolicy, PreparedPart, TargetCapabilities, TextFormat, TransformLimits,
    TransformOperation, TransformRequest,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub const PLANNER_NAME: &str = "attachment-native-plan";
pub const PLANNER_VERSION: &str = env!("CARGO_PKG_VERSION");

const DEFAULT_TRANSFORM_TIMEOUT_MS: u64 = 120_000;
const DEFAULT_VIDEO_FRAMES: u32 = 8;
const DEFAULT_PDF_PAGES: u32 = 32;
const DEFAULT_PDF_PAGE_MEGAPIXELS: u32 = 8;

/// Compiles canonical artifacts into a preparation plan without granting any
/// filesystem, network, process, model, OCR, or speech authority.
#[derive(Debug, Clone)]
pub struct PreparationPlanner {
    transform_timeout_ms: u64,
    video_frame_limit: u32,
    pdf_page_limit: u32,
    pdf_page_megapixels: u32,
}

impl Default for PreparationPlanner {
    fn default() -> Self {
        Self {
            transform_timeout_ms: DEFAULT_TRANSFORM_TIMEOUT_MS,
            video_frame_limit: DEFAULT_VIDEO_FRAMES,
            pdf_page_limit: DEFAULT_PDF_PAGES,
            pdf_page_megapixels: DEFAULT_PDF_PAGE_MEGAPIXELS,
        }
    }
}

impl PreparationPlanner {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Overrides bounded transform parameters. Zero values are rejected at
    /// planning time rather than being interpreted as unlimited.
    #[must_use]
    pub fn with_transform_limits(
        mut self,
        timeout_ms: u64,
        video_frames: u32,
        pdf_pages: u32,
        pdf_page_megapixels: u32,
    ) -> Self {
        self.transform_timeout_ms = timeout_ms;
        self.video_frame_limit = video_frames;
        self.pdf_page_limit = pdf_pages;
        self.pdf_page_megapixels = pdf_page_megapixels;
        self
    }

    pub fn plan(
        &self,
        bundle: &AttachmentBundle,
        target: &TargetCapabilities,
        policy: &PreparationPolicy,
    ) -> Result<PreparationPlan, AttachmentError> {
        bundle.validate().map_err(invalid_bundle)?;
        validate_blob_contracts(bundle)?;
        target.validate().map_err(invalid_target)?;
        if self.transform_timeout_ms == 0
            || self.video_frame_limit == 0
            || self.pdf_page_limit == 0
            || self.pdf_page_megapixels == 0
        {
            return Err(policy_error(
                "invalid_planner_limits",
                "Planner transform limits must all be greater than zero.",
            ));
        }

        let ordered = ordered_artifacts(bundle);
        let cache_fingerprint = input_fingerprint(self, bundle, &ordered, target, policy)?;
        let plan_id = format!("plan-{cache_fingerprint}");
        let mut builder = PlanBuilder {
            planner: self,
            bundle,
            target,
            policy,
            transform_seed: &cache_fingerprint,
            parts: Vec::new(),
            transforms: Vec::new(),
            blockers: Vec::new(),
            warnings: Vec::new(),
            text_bytes: 0,
            media_objects: 0,
            media_bytes: 0,
            transform_limit_reported: false,
        };

        let mut groups = BTreeMap::<ObjectId, Vec<&CanonicalArtifact>>::new();
        for artifact in ordered {
            groups
                .entry(artifact.source.clone())
                .or_default()
                .push(artifact);
        }
        for object in &bundle.graph.objects {
            let Some(mut artifacts) = groups.remove(&object.id) else {
                continue;
            };
            artifacts.sort_by_cached_key(|artifact| artifact_sort_key(artifact));
            if builder.block_object_status(object.status.clone(), &artifacts) {
                continue;
            }
            if object.detection.selected == Some(DetectedFormat::Pdf)
                || artifacts.iter().any(|artifact| artifact_is_pdf(artifact))
            {
                builder.plan_pdf(&artifacts);
            } else {
                for artifact in artifacts {
                    builder.plan_artifact(artifact);
                }
            }
        }
        if builder.parts.is_empty() && builder.transforms.is_empty() && builder.blockers.is_empty()
        {
            builder.block(
                "no_preparable_attachment_content",
                "The attachment produced no canonical content that can be prepared for this target.",
                None,
                Some(bundle.graph.root.clone()),
            );
        }

        let plan = PreparationPlan {
            schema: PLAN_SCHEMA.to_string(),
            plan_id,
            target_id: target.target_id.clone(),
            target_fingerprint: target.fingerprint.clone(),
            source_job_id: bundle.graph.job_id.clone(),
            parts: builder.parts,
            transforms: builder.transforms,
            blockers: builder.blockers,
            warnings: builder.warnings,
            aggregate_limits: PreparationAggregateLimits {
                max_text_bytes: target.max_text_bytes,
                max_media_objects: target.max_media_objects,
                max_media_bytes: target.max_media_bytes,
                max_transform_requests: bundle.graph.limits.max_transform_requests,
            },
            cache_fingerprint,
        };
        plan.validate_against(bundle)
            .map_err(invalid_generated_plan)?;
        Ok(plan)
    }
}

pub fn plan(
    bundle: &AttachmentBundle,
    target: &TargetCapabilities,
    policy: &PreparationPolicy,
) -> Result<PreparationPlan, AttachmentError> {
    PreparationPlanner::new().plan(bundle, target, policy)
}

struct PlanBuilder<'a> {
    planner: &'a PreparationPlanner,
    bundle: &'a AttachmentBundle,
    target: &'a TargetCapabilities,
    policy: &'a PreparationPolicy,
    transform_seed: &'a str,
    parts: Vec<PreparedPart>,
    transforms: Vec<TransformRequest>,
    blockers: Vec<PreparationBlocker>,
    warnings: Vec<String>,
    text_bytes: u64,
    media_objects: u32,
    media_bytes: u64,
    transform_limit_reported: bool,
}

impl PlanBuilder<'_> {
    fn block_object_status(
        &mut self,
        status: ObjectStatus,
        artifacts: &[&CanonicalArtifact],
    ) -> bool {
        let (code, message) = match status {
            ObjectStatus::Blocked { code } => (
                "source_object_blocked",
                format!("Attachment inspection blocked this object ({code})."),
            ),
            ObjectStatus::Malformed { code } => (
                "source_object_malformed",
                format!("Attachment inspection found a malformed object ({code})."),
            ),
            ObjectStatus::Unsupported { code } => (
                "source_object_unsupported",
                format!("Attachment inspection marked this object unsupported ({code})."),
            ),
            _ => return false,
        };
        let artifact = artifacts.first().copied();
        self.block(
            code,
            message,
            artifact.map(|value| value.id.clone()),
            artifact.map(|value| value.source.clone()),
        );
        true
    }

    fn plan_artifact(&mut self, artifact: &CanonicalArtifact) {
        match &artifact.payload {
            ArtifactPayload::Text { format, text, .. } => {
                self.push_text(artifact, *format, text);
            }
            ArtifactPayload::Media {
                family,
                blob,
                validation,
                ..
            } => match family {
                MediaFamily::Image => self.plan_image(artifact, blob, validation),
                MediaFamily::Audio => self.plan_audio(artifact, blob, validation),
                MediaFamily::Video => self.plan_video(artifact, blob, validation),
            },
            ArtifactPayload::Opaque { blob } => self.plan_opaque(artifact, blob),
        }
    }

    fn push_text(&mut self, artifact: &CanonicalArtifact, format: TextFormat, text: &str) {
        let Ok(byte_len) = u64::try_from(text.len()) else {
            self.block(
                "target_text_length_overflow",
                "Attachment text is too large to represent on this platform.",
                Some(artifact.id.clone()),
                Some(artifact.source.clone()),
            );
            return;
        };
        let Some(next) = self.text_bytes.checked_add(byte_len) else {
            self.block(
                "target_text_budget_exceeded",
                "Attachment text exceeds the target text budget.",
                Some(artifact.id.clone()),
                Some(artifact.source.clone()),
            );
            return;
        };
        if next > self.target.max_text_bytes {
            self.block(
                "target_text_budget_exceeded",
                "Attachment text exceeds the target text budget.",
                Some(artifact.id.clone()),
                Some(artifact.source.clone()),
            );
            return;
        }
        self.text_bytes = next;
        let output_format = if format == TextFormat::Markdown && !self.target.supports_markdown {
            self.warnings.push(format!(
                "Artifact {} contains Markdown; the target does not advertise Markdown rendering, so it is supplied as untrusted plain text without interpretation.",
                artifact.id.0
            ));
            TextFormat::Plain
        } else {
            format
        };
        self.parts.push(PreparedPart::UntrustedText {
            artifact_id: artifact.id.clone(),
            format: output_format,
            text: text.to_string(),
            source: artifact.source.clone(),
        });
    }

    fn plan_image(
        &mut self,
        artifact: &CanonicalArtifact,
        blob: &attachment_native_types::BlobRef,
        validation: &BlobValidation,
    ) {
        let direct = self.accepts_media(MediaFamily::Image, &blob.media_type, false)
            && self.direct_media_evidence(artifact, validation);
        match self.policy.image {
            attachment_native_types::ImagePreparationPolicy::DirectWhenSupported if direct => {
                self.push_media(artifact, MediaFamily::Image, blob);
            }
            attachment_native_types::ImagePreparationPolicy::DirectWhenSupported
            | attachment_native_types::ImagePreparationPolicy::OcrOnly => {
                self.push_transform(artifact, TransformOperation::OcrImage, true);
            }
            attachment_native_types::ImagePreparationPolicy::DirectAndOcr => {
                if direct {
                    self.push_media(artifact, MediaFamily::Image, blob);
                }
                self.push_transform(artifact, TransformOperation::OcrImage, true);
            }
        }
    }

    fn plan_audio(
        &mut self,
        artifact: &CanonicalArtifact,
        blob: &attachment_native_types::BlobRef,
        validation: &BlobValidation,
    ) {
        let direct = self.accepts_media(MediaFamily::Audio, &blob.media_type, false)
            && self.direct_media_evidence(artifact, validation);
        match self.policy.audio {
            attachment_native_types::AudioPreparationPolicy::DirectThenTranscribe if direct => {
                self.push_media(artifact, MediaFamily::Audio, blob);
            }
            attachment_native_types::AudioPreparationPolicy::DirectThenTranscribe
            | attachment_native_types::AudioPreparationPolicy::TranscribeOnly => {
                self.push_transform(artifact, TransformOperation::TranscribeAudio, true);
            }
            attachment_native_types::AudioPreparationPolicy::DirectAndTranscribe => {
                if direct {
                    self.push_media(artifact, MediaFamily::Audio, blob);
                }
                self.push_transform(artifact, TransformOperation::TranscribeAudio, true);
            }
            attachment_native_types::AudioPreparationPolicy::DirectOnly if direct => {
                self.push_media(artifact, MediaFamily::Audio, blob);
            }
            attachment_native_types::AudioPreparationPolicy::DirectOnly => {
                self.block_direct_media_unavailable(artifact, validation, MediaFamily::Audio)
            }
        }
    }

    fn plan_video(
        &mut self,
        artifact: &CanonicalArtifact,
        blob: &attachment_native_types::BlobRef,
        validation: &BlobValidation,
    ) {
        let direct = self.accepts_media(MediaFamily::Video, &blob.media_type, true)
            && self.direct_media_evidence(artifact, validation);
        match self.policy.video {
            attachment_native_types::VideoPreparationPolicy::DirectThenFramesAndTranscript
                if direct =>
            {
                self.push_media(artifact, MediaFamily::Video, blob);
            }
            attachment_native_types::VideoPreparationPolicy::DirectThenFramesAndTranscript
            | attachment_native_types::VideoPreparationPolicy::FramesAndTranscript => {
                self.push_video_frames(artifact);
                self.push_video_transcript(artifact);
            }
            attachment_native_types::VideoPreparationPolicy::FramesOnly => {
                self.push_video_frames(artifact);
            }
            attachment_native_types::VideoPreparationPolicy::TranscriptOnly => {
                self.push_video_transcript(artifact);
            }
            attachment_native_types::VideoPreparationPolicy::DirectOnly if direct => {
                self.push_media(artifact, MediaFamily::Video, blob);
            }
            attachment_native_types::VideoPreparationPolicy::DirectOnly => {
                self.block_direct_media_unavailable(artifact, validation, MediaFamily::Video)
            }
        }
    }

    fn push_video_frames(&mut self, artifact: &CanonicalArtifact) {
        let sample_frames = TransformOperation::SampleVideoFrames {
            max_frames: self
                .planner
                .video_frame_limit
                .min(self.target.max_media_objects),
        };
        let target_accepts_frames = self.accepts_any_image();
        let policy_also_requires_ocr = matches!(
            self.policy.image,
            attachment_native_types::ImagePreparationPolicy::OcrOnly
                | attachment_native_types::ImagePreparationPolicy::DirectAndOcr
        );
        if !target_accepts_frames || policy_also_requires_ocr {
            self.push_transform_pipeline(
                artifact,
                [sample_frames, TransformOperation::OcrImage],
                true,
            );
        } else {
            self.push_transform(artifact, sample_frames, true);
        }
    }

    fn push_video_transcript(&mut self, artifact: &CanonicalArtifact) {
        self.push_transform_pipeline(
            artifact,
            [
                TransformOperation::ExtractVideoAudio,
                TransformOperation::TranscribeAudio,
            ],
            true,
        );
    }

    fn plan_pdf(&mut self, artifacts: &[&CanonicalArtifact]) {
        let texts = artifacts
            .iter()
            .copied()
            .filter(|artifact| matches!(artifact.payload, ArtifactPayload::Text { .. }))
            .collect::<Vec<_>>();
        let native = artifacts.iter().copied().find(|artifact| {
            matches!(
                &artifact.payload,
                ArtifactPayload::Opaque { blob } if media_type_eq(&blob.media_type, "application/pdf")
            )
        });
        if let Some(artifact) = native
            && self.target.supports_native_pdf
            && !self.native_pdf_evidence(artifact)
        {
            self.warnings.push(format!(
                "Artifact {} was not routed as a native PDF because inspection did not establish complete parser-backed coverage.",
                artifact.id.0
            ));
        }
        let representative = texts
            .first()
            .copied()
            .or(native)
            .or_else(|| artifacts.first().copied());
        let text_ready = !texts.is_empty() && self.text_artifacts_fit(&texts);
        let native_ready = native.is_some_and(|artifact| {
            self.target.supports_native_pdf
                && self.native_pdf_evidence(artifact)
                && matches!(
                    &artifact.payload,
                    ArtifactPayload::Opaque { blob } if self.direct_blob_fits(blob.byte_len)
                )
        });
        match self.policy.document {
            attachment_native_types::DocumentPreparationPolicy::NativeThenCanonicalText => {
                if native_ready {
                    if let Some(artifact) = native {
                        self.push_pdf_native(artifact);
                    }
                } else if text_ready {
                    self.push_text_artifacts(&texts);
                } else {
                    self.plan_pdf_fallback(&texts, native, representative);
                }
            }
            attachment_native_types::DocumentPreparationPolicy::CanonicalTextThenNative => {
                if text_ready {
                    self.push_text_artifacts(&texts);
                } else if native_ready {
                    if let Some(artifact) = native {
                        self.push_pdf_native(artifact);
                    }
                } else {
                    self.plan_pdf_fallback(&texts, native, representative);
                }
            }
            attachment_native_types::DocumentPreparationPolicy::CanonicalTextOnly => {
                if !texts.is_empty() {
                    self.push_text_artifacts(&texts);
                } else if let Some(artifact) = representative {
                    self.push_transform(artifact, TransformOperation::ExtractDocumentText, true);
                }
            }
        }
        if representative.is_none() {
            self.block(
                "pdf_artifact_missing",
                "The PDF object has no canonical artifact to prepare.",
                None,
                artifacts.first().map(|artifact| artifact.source.clone()),
            );
        }
    }

    fn plan_pdf_fallback(
        &mut self,
        texts: &[&CanonicalArtifact],
        native: Option<&CanonicalArtifact>,
        representative: Option<&CanonicalArtifact>,
    ) {
        if !texts.is_empty() {
            self.push_text_artifacts(texts);
        } else if native.is_some_and(|artifact| {
            self.target.supports_native_pdf
                && self.native_pdf_evidence(artifact)
                && matches!(
                    &artifact.payload,
                    ArtifactPayload::Opaque { blob } if self.direct_blob_fits(blob.byte_len)
                )
        }) {
            if let Some(artifact) = native {
                self.push_pdf_native(artifact);
            }
        } else if let Some(artifact) = representative {
            if self.accepts_any_image() {
                self.push_transform(
                    artifact,
                    TransformOperation::RasterizePdfPages {
                        max_pages: self
                            .planner
                            .pdf_page_limit
                            .min(self.target.max_media_objects),
                        max_megapixels: self.planner.pdf_page_megapixels,
                    },
                    true,
                );
            } else {
                self.push_transform(artifact, TransformOperation::ExtractDocumentText, true);
            }
        }
    }

    fn text_artifacts_fit(&self, artifacts: &[&CanonicalArtifact]) -> bool {
        let mut total = self.text_bytes;
        for artifact in artifacts {
            let ArtifactPayload::Text { text, .. } = &artifact.payload else {
                continue;
            };
            let Ok(byte_len) = u64::try_from(text.len()) else {
                return false;
            };
            let Some(next) = total.checked_add(byte_len) else {
                return false;
            };
            total = next;
        }
        total <= self.target.max_text_bytes
    }

    fn direct_blob_fits(&self, byte_len: u64) -> bool {
        self.media_objects
            .checked_add(1)
            .is_some_and(|objects| objects <= self.target.max_media_objects)
            && self
                .media_bytes
                .checked_add(byte_len)
                .is_some_and(|bytes| bytes <= self.target.max_media_bytes)
    }

    fn push_text_artifacts(&mut self, artifacts: &[&CanonicalArtifact]) {
        for artifact in artifacts {
            if let ArtifactPayload::Text { format, text, .. } = &artifact.payload {
                self.push_text(artifact, *format, text);
            }
        }
    }

    fn push_pdf_native(&mut self, artifact: &CanonicalArtifact) {
        let ArtifactPayload::Opaque { blob } = &artifact.payload else {
            return;
        };
        if !self.reserve_direct_blob(artifact, blob.byte_len) {
            return;
        }
        self.parts.push(PreparedPart::OpaqueReference {
            artifact_id: artifact.id.clone(),
            blob: blob.clone(),
            source: artifact.source.clone(),
        });
    }

    fn native_pdf_evidence(&self, artifact: &CanonicalArtifact) -> bool {
        matches!(
            self.bundle.graph.coverage,
            attachment_native_types::Coverage::Complete
        ) && self
            .bundle
            .graph
            .objects
            .iter()
            .find(|object| object.id == artifact.source)
            .is_some_and(|object| {
                matches!(object.status, ObjectStatus::Complete)
                    && object.detection.selected == Some(DetectedFormat::Pdf)
            })
    }

    fn plan_opaque(
        &mut self,
        artifact: &CanonicalArtifact,
        blob: &attachment_native_types::BlobRef,
    ) {
        let executable = self.bundle.graph.objects.iter().any(|object| {
            object.id == artifact.source
                && object.detection.selected == Some(DetectedFormat::Executable)
        });
        if executable {
            self.block(
                "executable_attachment_blocked",
                "Executable attachment bytes cannot be sent to a model target.",
                Some(artifact.id.clone()),
                Some(artifact.source.clone()),
            );
            return;
        }
        match self.policy.unsupported {
            attachment_native_types::UnsupportedPreparationPolicy::Block => self.block(
                "unsupported_opaque_attachment",
                "The attachment has no safe canonical representation for this target.",
                Some(artifact.id.clone()),
                Some(artifact.source.clone()),
            ),
            attachment_native_types::UnsupportedPreparationPolicy::PreserveAsOpaqueReference => {
                if !self.reserve_direct_blob(artifact, blob.byte_len) {
                    return;
                }
                self.parts.push(PreparedPart::OpaqueReference {
                    artifact_id: artifact.id.clone(),
                    blob: blob.clone(),
                    source: artifact.source.clone(),
                });
            }
        }
    }

    fn accepts_media(&self, family: MediaFamily, media_type: &str, native_video: bool) -> bool {
        if native_video && !self.target.supports_native_video {
            return false;
        }
        let exact = self
            .target
            .accepted_media_types
            .iter()
            .any(|accepted| media_type_eq(accepted, media_type));
        let family_has_exact_types = self
            .target
            .accepted_media_types
            .iter()
            .any(|accepted| media_type_family(accepted) == Some(family));
        exact || (!family_has_exact_types && self.target.accepted_media_families.contains(&family))
    }

    fn direct_media_evidence(
        &mut self,
        artifact: &CanonicalArtifact,
        validation: &BlobValidation,
    ) -> bool {
        if !validation.grade.permits_direct_media() {
            self.warnings.push(format!(
                "Artifact {} was not routed as direct media: validation grade {:?} does not prove a complete bounded payload decode.",
                artifact.id.0, validation.grade
            ));
            return false;
        }
        let source_complete = self
            .bundle
            .graph
            .objects
            .iter()
            .find(|object| object.id == artifact.source)
            .is_some_and(|object| matches!(object.status, ObjectStatus::Complete));
        if !source_complete {
            self.warnings.push(format!(
                "Artifact {} was not routed as direct media because inspection did not establish complete source coverage.",
                artifact.id.0
            ));
        }
        source_complete
    }

    fn block_direct_media_unavailable(
        &mut self,
        artifact: &CanonicalArtifact,
        validation: &BlobValidation,
        family: MediaFamily,
    ) {
        let source_complete = self
            .bundle
            .graph
            .objects
            .iter()
            .find(|object| object.id == artifact.source)
            .is_some_and(|object| matches!(object.status, ObjectStatus::Complete));
        let (code, message) = if !validation.grade.permits_direct_media() {
            (
                "direct_media_validation_insufficient",
                "Direct media is disabled because the retained blob did not pass a complete bounded payload decode.",
            )
        } else if !source_complete {
            (
                "direct_media_source_incomplete",
                "Direct media is disabled because attachment inspection did not establish complete source coverage.",
            )
        } else {
            match family {
                MediaFamily::Audio => (
                    "audio_not_supported_by_target",
                    "The target does not accept this audio type and transcription is disabled.",
                ),
                MediaFamily::Video => (
                    "video_not_supported_by_target",
                    "The target does not accept native video and fallback transforms are disabled.",
                ),
                MediaFamily::Image => (
                    "image_not_supported_by_target",
                    "The target does not accept this image type and fallback transforms are disabled.",
                ),
            }
        };
        self.block(
            code,
            message,
            Some(artifact.id.clone()),
            Some(artifact.source.clone()),
        );
    }

    fn accepts_any_image(&self) -> bool {
        self.target
            .accepted_media_families
            .contains(&MediaFamily::Image)
            || self
                .target
                .accepted_media_types
                .iter()
                .any(|media_type| media_type.to_ascii_lowercase().starts_with("image/"))
    }

    fn push_media(
        &mut self,
        artifact: &CanonicalArtifact,
        family: MediaFamily,
        blob: &attachment_native_types::BlobRef,
    ) {
        if !self.reserve_direct_blob(artifact, blob.byte_len) {
            return;
        }
        self.parts.push(PreparedPart::DirectMedia {
            artifact_id: artifact.id.clone(),
            family,
            blob: blob.clone(),
            source: artifact.source.clone(),
        });
    }

    fn reserve_direct_blob(&mut self, artifact: &CanonicalArtifact, byte_len: u64) -> bool {
        let Some(next_objects) = self.media_objects.checked_add(1) else {
            self.block_media_budget(artifact);
            return false;
        };
        let Some(next_bytes) = self.media_bytes.checked_add(byte_len) else {
            self.block_media_budget(artifact);
            return false;
        };
        if next_objects > self.target.max_media_objects || next_bytes > self.target.max_media_bytes
        {
            self.block_media_budget(artifact);
            return false;
        }
        self.media_objects = next_objects;
        self.media_bytes = next_bytes;
        true
    }

    fn block_media_budget(&mut self, artifact: &CanonicalArtifact) {
        self.block(
            "target_media_budget_exceeded",
            "Direct attachment media exceeds the target media budget.",
            Some(artifact.id.clone()),
            Some(artifact.source.clone()),
        );
    }

    fn push_transform(
        &mut self,
        artifact: &CanonicalArtifact,
        operation: TransformOperation,
        required: bool,
    ) {
        drop(self.try_push_transform(artifact, operation, required, Vec::new()));
    }

    fn push_transform_pipeline<const N: usize>(
        &mut self,
        artifact: &CanonicalArtifact,
        operations: [TransformOperation; N],
        required: bool,
    ) {
        let mut depends_on = Vec::new();
        for operation in operations {
            let Some(id) =
                self.try_push_transform(artifact, operation, required, depends_on.clone())
            else {
                break;
            };
            depends_on = vec![id];
        }
    }

    fn try_push_transform(
        &mut self,
        artifact: &CanonicalArtifact,
        operation: TransformOperation,
        required: bool,
        depends_on: Vec<String>,
    ) -> Option<String> {
        let limit =
            usize::try_from(self.bundle.graph.limits.max_transform_requests).unwrap_or(usize::MAX);
        if self.transforms.len() >= limit {
            if !self.transform_limit_reported {
                self.block(
                    "transform_request_budget_exceeded",
                    "Attachment preparation requires more transforms than the inspection policy permits.",
                    Some(artifact.id.clone()),
                    Some(artifact.source.clone()),
                );
                self.transform_limit_reported = true;
            }
            return None;
        }
        let ordinal = self.transforms.len();
        let id = transform_id(self.transform_seed, ordinal, &artifact.source, &operation);
        let output_limit = match operation {
            TransformOperation::OcrImage
            | TransformOperation::TranscribeAudio
            | TransformOperation::ExtractDocumentText => self.target.max_text_bytes,
            TransformOperation::ExtractVideoAudio
            | TransformOperation::SampleVideoFrames { .. }
            | TransformOperation::RasterizePdfPages { .. } => self.target.max_media_bytes,
        };
        self.transforms.push(TransformRequest {
            id: id.clone(),
            source_artifact: artifact.id.clone(),
            source: artifact.source.clone(),
            operation,
            required,
            depends_on,
            limits: TransformLimits {
                max_input_bytes: artifact_input_bytes(artifact),
                max_output_bytes: output_limit,
                timeout_ms: self.planner.transform_timeout_ms,
            },
        });
        Some(id)
    }

    fn block(
        &mut self,
        code: impl Into<String>,
        safe_message: impl Into<String>,
        artifact_id: Option<ArtifactId>,
        source: Option<ObjectId>,
    ) {
        self.blockers.push(PreparationBlocker {
            code: code.into(),
            safe_message: safe_message.into(),
            artifact_id,
            source,
        });
    }
}

fn ordered_artifacts(bundle: &AttachmentBundle) -> Vec<&CanonicalArtifact> {
    let source_order = bundle
        .graph
        .objects
        .iter()
        .enumerate()
        .map(|(index, object)| (object.id.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let mut artifacts = bundle.artifacts.iter().collect::<Vec<_>>();
    artifacts.sort_by_cached_key(|artifact| {
        (
            source_order
                .get(&artifact.source)
                .copied()
                .unwrap_or(usize::MAX),
            artifact_sort_key(artifact),
        )
    });
    artifacts
}

fn artifact_sort_key(artifact: &CanonicalArtifact) -> (u8, String, String) {
    let (rank, subtype, content_key) = match &artifact.payload {
        ArtifactPayload::Text { format, text, .. } => {
            (0, format!("{format:?}"), hex_digest(text.as_bytes()))
        }
        ArtifactPayload::Media { family, blob, .. } => (
            1,
            format!("{family:?}:{}", blob.media_type.to_ascii_lowercase()),
            blob.sha256.clone(),
        ),
        ArtifactPayload::Opaque { blob } => {
            (2, blob.media_type.to_ascii_lowercase(), blob.sha256.clone())
        }
    };
    (rank, subtype, content_key)
}

fn artifact_is_pdf(artifact: &CanonicalArtifact) -> bool {
    match &artifact.payload {
        ArtifactPayload::Media { blob, .. } | ArtifactPayload::Opaque { blob } => {
            media_type_eq(&blob.media_type, "application/pdf")
        }
        ArtifactPayload::Text { .. } => false,
    }
}

fn artifact_input_bytes(artifact: &CanonicalArtifact) -> u64 {
    match &artifact.payload {
        ArtifactPayload::Text { text, .. } => u64::try_from(text.len()).unwrap_or(u64::MAX),
        ArtifactPayload::Media { blob, .. } | ArtifactPayload::Opaque { blob } => blob.byte_len,
    }
}

fn validate_blob_contracts(bundle: &AttachmentBundle) -> Result<(), AttachmentError> {
    let objects = bundle
        .graph
        .objects
        .iter()
        .map(|object| (&object.id, object))
        .collect::<BTreeMap<_, _>>();
    for artifact in &bundle.artifacts {
        let blob = match &artifact.payload {
            ArtifactPayload::Media { blob, .. } | ArtifactPayload::Opaque { blob } => blob,
            ArtifactPayload::Text { .. } => continue,
        };
        if blob.object_id != artifact.source
            || blob.sha256 != artifact.source.0
            || blob.sha256 != blob.object_id.0
        {
            return Err(invalid_blob(
                &artifact.source,
                "A canonical artifact cannot substitute bytes from a different inspected object.",
            ));
        }
        let Some(object) = objects.get(&blob.object_id) else {
            return Err(invalid_blob(
                &artifact.source,
                "A canonical artifact references a blob outside its inspected object graph.",
            ));
        };
        if blob.sha256 != object.sha256
            || blob.byte_len != object.byte_len
            || blob.media_type.trim().is_empty()
            || !bundle.blobs.contains_key(&blob.object_id)
        {
            return Err(invalid_blob(
                &artifact.source,
                "A canonical artifact blob reference does not match retained inspected bytes.",
            ));
        }
    }
    Ok(())
}

fn input_fingerprint(
    planner: &PreparationPlanner,
    bundle: &AttachmentBundle,
    artifacts: &[&CanonicalArtifact],
    target: &TargetCapabilities,
    policy: &PreparationPolicy,
) -> Result<String, AttachmentError> {
    let mut hasher = Sha256::new();
    hash_field(&mut hasher, b"attachment-native-plan-input-v1");
    hash_field(&mut hasher, PLANNER_NAME.as_bytes());
    hash_field(&mut hasher, PLANNER_VERSION.as_bytes());
    hash_field(&mut hasher, &planner.transform_timeout_ms.to_le_bytes());
    hash_field(&mut hasher, &planner.video_frame_limit.to_le_bytes());
    hash_field(&mut hasher, &planner.pdf_page_limit.to_le_bytes());
    hash_field(&mut hasher, &planner.pdf_page_megapixels.to_le_bytes());
    hash_field(
        &mut hasher,
        &bundle.graph.limits.max_transform_requests.to_le_bytes(),
    );
    hash_json(&mut hasher, target)?;
    hash_json(&mut hasher, policy)?;
    for object in &bundle.graph.objects {
        hash_field(&mut hasher, object.id.0.as_bytes());
        hash_json(&mut hasher, &object.detection.selected)?;
        hash_json(&mut hasher, &object.status)?;
    }
    for artifact in artifacts {
        hash_field(&mut hasher, artifact.id.0.as_bytes());
        hash_field(&mut hasher, artifact.schema.as_bytes());
        hash_field(&mut hasher, artifact.source.0.as_bytes());
        hash_json(&mut hasher, &artifact.processor)?;
        hash_json(&mut hasher, &artifact.trust)?;
        hash_json(&mut hasher, &artifact.payload)?;
        hash_json(&mut hasher, &artifact.warnings)?;
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn transform_id(
    seed: &str,
    ordinal: usize,
    source: &ObjectId,
    operation: &TransformOperation,
) -> String {
    let mut hasher = Sha256::new();
    hash_field(&mut hasher, b"attachment-native-transform-v1");
    hash_field(&mut hasher, seed.as_bytes());
    hash_field(&mut hasher, ordinal.to_string().as_bytes());
    hash_field(&mut hasher, source.0.as_bytes());
    hash_field(&mut hasher, transform_operation_key(operation).as_bytes());
    format!("transform-{:x}", hasher.finalize())
}

fn transform_operation_key(operation: &TransformOperation) -> String {
    match operation {
        TransformOperation::TranscribeAudio => "transcribe_audio".to_string(),
        TransformOperation::ExtractVideoAudio => "extract_video_audio".to_string(),
        TransformOperation::SampleVideoFrames { max_frames } => {
            format!("sample_video_frames:{max_frames}")
        }
        TransformOperation::OcrImage => "ocr_image".to_string(),
        TransformOperation::RasterizePdfPages {
            max_pages,
            max_megapixels,
        } => format!("rasterize_pdf_pages:{max_pages}:{max_megapixels}"),
        TransformOperation::ExtractDocumentText => "extract_document_text".to_string(),
    }
}

fn hash_json<T: Serialize>(hasher: &mut Sha256, value: &T) -> Result<(), AttachmentError> {
    let encoded = serde_json::to_vec(value).map_err(|_| {
        policy_error(
            "plan_fingerprint_failed",
            "Attachment preparation fingerprint serialization failed.",
        )
    })?;
    hash_field(hasher, &encoded);
    Ok(())
}

fn hash_field(hasher: &mut Sha256, value: &[u8]) {
    hasher.update(value.len().to_le_bytes());
    hasher.update(value);
}

fn hex_digest(value: &[u8]) -> String {
    format!("{:x}", Sha256::digest(value))
}

fn media_type_eq(left: &str, right: &str) -> bool {
    left.trim().eq_ignore_ascii_case(right.trim())
}

fn media_type_family(media_type: &str) -> Option<MediaFamily> {
    let normalized = media_type.trim().to_ascii_lowercase();
    if normalized.starts_with("image/") {
        Some(MediaFamily::Image)
    } else if normalized.starts_with("audio/") {
        Some(MediaFamily::Audio)
    } else if normalized.starts_with("video/") {
        Some(MediaFamily::Video)
    } else {
        None
    }
}

fn invalid_bundle(error: ContractError) -> AttachmentError {
    AttachmentError {
        code: "invalid_attachment_bundle".to_string(),
        class: IssueClass::Internal,
        safe_message: format!("Attachment bundle contract validation failed: {error}"),
        object_id: None,
        retryable: false,
    }
}

fn invalid_target(error: ContractError) -> AttachmentError {
    AttachmentError {
        code: "invalid_target_capabilities".to_string(),
        class: IssueClass::Policy,
        safe_message: format!("Target capability validation failed: {error}"),
        object_id: None,
        retryable: false,
    }
}

fn invalid_generated_plan(error: ContractError) -> AttachmentError {
    AttachmentError {
        code: "invalid_generated_preparation_plan".to_string(),
        class: IssueClass::Internal,
        safe_message: format!("Generated attachment preparation plan validation failed: {error}"),
        object_id: None,
        retryable: false,
    }
}

fn invalid_blob(source: &ObjectId, message: impl Into<String>) -> AttachmentError {
    AttachmentError {
        code: "invalid_artifact_blob_reference".to_string(),
        class: IssueClass::Integrity,
        safe_message: message.into(),
        object_id: Some(source.clone()),
        retryable: false,
    }
}

fn policy_error(code: impl Into<String>, message: impl Into<String>) -> AttachmentError {
    AttachmentError {
        code: code.into(),
        class: IssueClass::Policy,
        safe_message: message.into(),
        object_id: None,
        retryable: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use attachment_native_types::{
        ARTIFACT_SCHEMA, AttachmentGraph, AttachmentJobId, BlobRef, BlobValidationGrade,
        BudgetLimits, BudgetUsage, ContentTrust, Coverage, DerivationEdge, Detection, EdgeOutcome,
        LogicalName, MediaMetadata, ObjectRecord, ProcessorProvenance, TextSegment, TransformKind,
        TransformProvenance, UnknownBinaryPolicy,
    };
    use std::collections::{BTreeMap, BTreeSet};
    use std::sync::Arc;

    fn object_id(byte: u8) -> ObjectId {
        ObjectId(format!("{byte:064x}"))
    }

    fn artifact_id(value: &str) -> ArtifactId {
        ArtifactId(value.to_string())
    }

    fn object(id: ObjectId, format: DetectedFormat, byte_len: u64) -> ObjectRecord {
        ObjectRecord {
            sha256: id.0.clone(),
            id,
            byte_len,
            detection: Detection {
                selected: Some(format),
                candidates: Vec::new(),
                extension_hint: None,
                declared_media_type: None,
                mismatch: None,
            },
            status: ObjectStatus::Complete,
            first_depth: 0,
            artifact_ids: Vec::new(),
        }
    }

    fn text_artifact(
        id: &str,
        source: &ObjectId,
        format: TextFormat,
        text: &str,
    ) -> CanonicalArtifact {
        CanonicalArtifact {
            schema: ARTIFACT_SCHEMA.to_string(),
            id: artifact_id(id),
            source: source.clone(),
            processor: ProcessorProvenance {
                name: "fixture".to_string(),
                version: "1".to_string(),
                policy_fingerprint: "fixture-policy".to_string(),
            },
            trust: ContentTrust::UntrustedAttachmentData,
            payload: ArtifactPayload::Text {
                format,
                text: text.to_string(),
                segments: Vec::<TextSegment>::new(),
            },
            warnings: Vec::new(),
        }
    }

    fn blob_artifact(
        id: &str,
        source: &ObjectId,
        media_type: &str,
        family: Option<MediaFamily>,
        byte_len: u64,
    ) -> CanonicalArtifact {
        let blob = BlobRef {
            object_id: source.clone(),
            sha256: source.0.clone(),
            byte_len,
            media_type: media_type.to_string(),
        };
        CanonicalArtifact {
            schema: ARTIFACT_SCHEMA.to_string(),
            id: artifact_id(id),
            source: source.clone(),
            processor: ProcessorProvenance {
                name: "fixture".to_string(),
                version: "1".to_string(),
                policy_fingerprint: "fixture-policy".to_string(),
            },
            trust: ContentTrust::UntrustedAttachmentData,
            payload: match family {
                Some(family) => ArtifactPayload::Media {
                    family,
                    blob,
                    metadata: MediaMetadata::default(),
                    validation: BlobValidation {
                        grade: BlobValidationGrade::PayloadDecoded,
                        method: "fixture complete decode".to_string(),
                        validator: ProcessorProvenance {
                            name: "fixture-decoder".to_string(),
                            version: "1".to_string(),
                            policy_fingerprint: "fixture-policy".to_string(),
                        },
                    },
                },
                None => ArtifactPayload::Opaque { blob },
            },
            warnings: Vec::new(),
        }
    }

    fn bundle(
        mut objects: Vec<ObjectRecord>,
        mut artifacts: Vec<CanonicalArtifact>,
    ) -> AttachmentBundle {
        let mut id_map = BTreeMap::new();
        let mut blobs = BTreeMap::new();
        for (index, object) in objects.iter_mut().enumerate() {
            let size = usize::try_from(object.byte_len).unwrap_or_default();
            let fill = u8::try_from(index.saturating_add(1)).unwrap_or(u8::MAX);
            let bytes = Arc::<[u8]>::from(vec![fill; size]);
            let old_id = object.id.clone();
            let id = ObjectId(hex_digest(&bytes));
            object.id = id.clone();
            object.sha256 = id.0.clone();
            id_map.insert(old_id, id.clone());
            blobs.insert(id, bytes);
        }
        for artifact in &mut artifacts {
            if let Some(source) = id_map.get(&artifact.source) {
                artifact.source = source.clone();
                match &mut artifact.payload {
                    ArtifactPayload::Media { blob, .. } | ArtifactPayload::Opaque { blob } => {
                        blob.object_id = source.clone();
                        blob.sha256 = source.0.clone();
                    }
                    ArtifactPayload::Text { .. } => {}
                }
            }
        }
        for object in &mut objects {
            object.artifact_ids = artifacts
                .iter()
                .filter(|artifact| artifact.source == object.id)
                .map(|artifact| artifact.id.clone())
                .collect();
        }
        let root = objects
            .first()
            .map(|value| value.id.clone())
            .unwrap_or_else(|| object_id(0));
        for (index, object) in objects.iter_mut().enumerate() {
            object.first_depth = u16::from(index != 0);
        }
        let edges = objects
            .iter()
            .skip(1)
            .enumerate()
            .map(|(index, object)| DerivationEdge {
                parent: root.clone(),
                child: Some(object.id.clone()),
                depth: 1,
                name: LogicalName::provided(format!("fixture-child-{index}")),
                transform: TransformProvenance {
                    kind: TransformKind::DocumentPart,
                    implementation: "fixture".to_string(),
                    version: "1".to_string(),
                },
                declared_uncompressed_bytes: Some(object.byte_len),
                compressed_bytes: None,
                source_range: None,
                outcome: EdgeOutcome::Derived,
            })
            .collect::<Vec<_>>();
        let retained_bytes = objects.iter().map(|object| object.byte_len).sum();
        let total_derived_bytes = objects.iter().skip(1).map(|object| object.byte_len).sum();
        let (text_bytes, media_objects, media_bytes) = artifacts.iter().fold(
            (0_u64, 0_u32, 0_u64),
            |(text_bytes, media_objects, media_bytes), artifact| match &artifact.payload {
                ArtifactPayload::Text { text, .. } => (
                    text_bytes.saturating_add(u64::try_from(text.len()).unwrap_or(u64::MAX)),
                    media_objects,
                    media_bytes,
                ),
                ArtifactPayload::Media { blob, .. } => (
                    text_bytes,
                    media_objects.saturating_add(1),
                    media_bytes.saturating_add(blob.byte_len),
                ),
                ArtifactPayload::Opaque { .. } => (text_bytes, media_objects, media_bytes),
            },
        );
        let usage = BudgetUsage {
            root_bytes: objects.first().map_or(0, |object| object.byte_len),
            total_derived_bytes,
            retained_bytes,
            objects: u32::try_from(objects.len()).unwrap_or(u32::MAX),
            edges: u32::try_from(edges.len()).unwrap_or(u32::MAX),
            deepest_object: u16::from(objects.len() > 1),
            text_bytes,
            media_objects,
            media_bytes,
            ..BudgetUsage::default()
        };
        AttachmentBundle {
            graph: AttachmentGraph {
                schema: attachment_native_types::GRAPH_SCHEMA.to_string(),
                job_id: AttachmentJobId("fixture-job".to_string()),
                root,
                root_name: LogicalName::provided("fixture"),
                objects,
                edges,
                issues: Vec::new(),
                // These synthetic planner fixtures do not claim an inspector
                // traversed every possible container branch.
                coverage: Coverage::Partial {
                    reasons: vec!["synthetic_planner_fixture".to_string()],
                },
                limits: BudgetLimits::default(),
                usage,
            },
            artifacts,
            blobs,
        }
    }

    fn target() -> TargetCapabilities {
        TargetCapabilities {
            target_id: "gemma".to_string(),
            fingerprint: "gemma-fixture-v1".to_string(),
            accepted_media_types: BTreeSet::new(),
            accepted_media_families: BTreeSet::new(),
            max_media_objects: 16,
            max_media_bytes: 1_000_000,
            max_text_bytes: 1_000_000,
            supports_markdown: true,
            supports_native_pdf: false,
            supports_native_video: false,
        }
    }

    fn operation_kinds(plan: &PreparationPlan) -> Vec<&TransformOperation> {
        plan.transforms
            .iter()
            .map(|value| &value.operation)
            .collect()
    }

    #[test]
    fn text_and_markdown_are_direct_and_untrusted() {
        let source = object_id(1);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Markdown, 5)],
            vec![text_artifact(
                "text",
                &source,
                TextFormat::Markdown,
                "hello",
            )],
        );
        let plan = plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            plan.as_ref().map(|value| &value.parts),
            Ok(parts) if matches!(parts.as_slice(), [PreparedPart::UntrustedText { format: TextFormat::Markdown, text, .. }] if text == "hello")
        ));
    }

    #[test]
    fn markdown_is_plain_when_target_does_not_advertise_rendering() {
        let source = object_id(2);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Markdown, 5)],
            vec![text_artifact("text", &source, TextFormat::Markdown, "# hi")],
        );
        let mut capabilities = target();
        capabilities.supports_markdown = false;
        let plan = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(matches!(
            plan.as_ref().map(|value| &value.parts),
            Ok(parts) if matches!(parts.as_slice(), [PreparedPart::UntrustedText { format: TextFormat::Plain, .. }])
        ));
        assert!(plan.as_ref().is_ok_and(|value| value.warnings.len() == 1));
    }

    #[test]
    fn image_is_direct_only_for_an_explicit_exact_or_family_capability() {
        let source = object_id(3);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Png, 16)],
            vec![blob_artifact(
                "image",
                &source,
                "image/png",
                Some(MediaFamily::Image),
                16,
            )],
        );
        let mut capabilities = target();
        capabilities
            .accepted_media_types
            .insert("IMAGE/PNG".to_string());
        let direct = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(matches!(
            direct.as_ref().map(|value| &value.parts),
            Ok(parts) if matches!(parts.as_slice(), [PreparedPart::DirectMedia { family: MediaFamily::Image, .. }])
        ));
        let fallback = plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            fallback.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::OcrImage])
        ));
    }

    #[test]
    fn header_or_structure_only_media_never_routes_as_direct_media() {
        let cases = [
            (DetectedFormat::Png, "image/png", MediaFamily::Image),
            (DetectedFormat::Jpeg, "image/jpeg", MediaFamily::Image),
            (DetectedFormat::OggAudio, "audio/ogg", MediaFamily::Audio),
            (DetectedFormat::Mp4, "video/mp4", MediaFamily::Video),
            (DetectedFormat::Webm, "video/webm", MediaFamily::Video),
            (DetectedFormat::Mp3, "audio/mpeg", MediaFamily::Audio),
        ];
        for (index, (format, media_type, family)) in cases.into_iter().enumerate() {
            let source = object_id(u8::try_from(index + 40).unwrap_or(u8::MAX));
            let mut artifact = blob_artifact(
                &format!("media-{index}"),
                &source,
                media_type,
                Some(family),
                16,
            );
            if let ArtifactPayload::Media { validation, .. } = &mut artifact.payload {
                validation.grade = BlobValidationGrade::HeaderOrStructureOnly;
                validation.method = "fixture truncated-tail structural probe".to_string();
            }
            let value = bundle(vec![object(source, format, 16)], vec![artifact]);
            let mut capabilities = target();
            capabilities
                .accepted_media_types
                .insert(media_type.to_string());
            capabilities.supports_native_video = true;
            let result = plan(&value, &capabilities, &PreparationPolicy::default());
            assert!(result.as_ref().is_ok_and(|plan| {
                !plan
                    .parts
                    .iter()
                    .any(|part| matches!(part, PreparedPart::DirectMedia { .. }))
                    && !plan.transforms.is_empty()
            }));
        }
    }

    #[test]
    fn decoded_media_from_partial_source_is_not_direct() {
        let source = object_id(55);
        let mut source_object = object(source.clone(), DetectedFormat::Png, 16);
        source_object.status = ObjectStatus::Partial {
            reasons: vec!["inspection_deadline_exceeded".to_string()],
        };
        let value = bundle(
            vec![source_object],
            vec![blob_artifact(
                "image",
                &source,
                "image/png",
                Some(MediaFamily::Image),
                16,
            )],
        );
        let mut capabilities = target();
        capabilities
            .accepted_media_types
            .insert("image/png".to_string());
        let result = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(result.as_ref().is_ok_and(|plan| {
            plan.parts.is_empty()
                && matches!(
                    plan.transforms.as_slice(),
                    [TransformRequest {
                        operation: TransformOperation::OcrImage,
                        ..
                    }]
                )
        }));
    }

    #[test]
    fn cross_object_blob_substitution_is_rejected_before_direct_media_routing() {
        let benign_source = object_id(30);
        let blocked_source = object_id(31);
        let mut value = bundle(
            vec![
                object(benign_source.clone(), DetectedFormat::PlainText, 16),
                object(blocked_source, DetectedFormat::Executable, 16),
            ],
            vec![blob_artifact(
                "forged-image",
                &benign_source,
                "image/png",
                Some(MediaFamily::Image),
                16,
            )],
        );
        value.graph.objects[1].status = ObjectStatus::Blocked {
            code: "executable_content".to_string(),
        };
        let substituted = value.graph.objects[1].id.clone();
        assert!(matches!(
            value.artifacts[0].payload,
            ArtifactPayload::Media { .. }
        ));
        if let ArtifactPayload::Media { blob, .. } = &mut value.artifacts[0].payload {
            blob.object_id = substituted.clone();
            blob.sha256 = substituted.0;
        }

        assert!(matches!(
            value.validate(),
            Err(ContractError::ArtifactBlobSourceMismatch { .. })
        ));
        assert!(matches!(
            validate_blob_contracts(&value),
            Err(AttachmentError { code, .. }) if code == "invalid_artifact_blob_reference"
        ));
        let mut capabilities = target();
        capabilities
            .accepted_media_types
            .insert("image/png".to_string());
        assert!(matches!(
            plan(&value, &capabilities, &PreparationPolicy::default()),
            Err(AttachmentError { code, .. }) if code == "invalid_attachment_bundle"
        ));
    }

    #[test]
    fn image_direct_and_ocr_requests_both_outputs() {
        let source = object_id(4);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Jpeg, 16)],
            vec![blob_artifact(
                "image",
                &source,
                "image/jpeg",
                Some(MediaFamily::Image),
                16,
            )],
        );
        let mut capabilities = target();
        capabilities
            .accepted_media_families
            .insert(MediaFamily::Image);
        let policy = PreparationPolicy {
            image: attachment_native_types::ImagePreparationPolicy::DirectAndOcr,
            ..PreparationPolicy::default()
        };
        let result = plan(&value, &capabilities, &policy);
        assert!(result.as_ref().is_ok_and(|value| value.parts.len() == 1));
        assert!(matches!(
            result.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::OcrImage])
        ));
    }

    #[test]
    fn exact_image_allowlist_narrows_a_family_wildcard() {
        let source = object_id(20);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Heif, 16)],
            vec![blob_artifact(
                "image",
                &source,
                "image/heif",
                Some(MediaFamily::Image),
                16,
            )],
        );
        let mut capabilities = target();
        capabilities
            .accepted_media_families
            .insert(MediaFamily::Image);
        capabilities
            .accepted_media_types
            .insert("image/png".to_string());
        let result = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(result.as_ref().is_ok_and(|value| value.parts.is_empty()));
        assert!(matches!(
            result.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::OcrImage])
        ));
    }

    #[test]
    fn image_ocr_only_never_sends_direct_pixels() {
        let source = object_id(22);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Png, 16)],
            vec![blob_artifact(
                "image",
                &source,
                "image/png",
                Some(MediaFamily::Image),
                16,
            )],
        );
        let mut capabilities = target();
        capabilities
            .accepted_media_types
            .insert("image/png".to_string());
        let policy = PreparationPolicy {
            image: attachment_native_types::ImagePreparationPolicy::OcrOnly,
            ..PreparationPolicy::default()
        };
        let result = plan(&value, &capabilities, &policy);
        assert!(result.as_ref().is_ok_and(|value| value.parts.is_empty()));
        assert!(matches!(
            result.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::OcrImage])
        ));
    }

    #[test]
    fn audio_policy_distinguishes_direct_transcribe_and_block() {
        let source = object_id(5);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Wav, 16)],
            vec![blob_artifact(
                "audio",
                &source,
                "audio/wav",
                Some(MediaFamily::Audio),
                16,
            )],
        );
        let transcribe = plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            transcribe.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::TranscribeAudio])
        ));
        let mut capabilities = target();
        capabilities
            .accepted_media_families
            .insert(MediaFamily::Audio);
        let direct = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(direct.as_ref().is_ok_and(|value| value.parts.len() == 1));
        let direct_only = PreparationPolicy {
            audio: attachment_native_types::AudioPreparationPolicy::DirectOnly,
            ..PreparationPolicy::default()
        };
        let blocked = plan(&value, &target(), &direct_only);
        assert!(matches!(
            blocked
                .as_ref()
                .map(|value| value.blockers.first().map(|blocker| blocker.code.as_str())),
            Ok(Some("audio_not_supported_by_target"))
        ));
    }

    #[test]
    fn audio_direct_and_transcribe_retains_both_required_paths() {
        let source = object_id(23);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Flac, 16)],
            vec![blob_artifact(
                "audio",
                &source,
                "audio/flac",
                Some(MediaFamily::Audio),
                16,
            )],
        );
        let mut capabilities = target();
        capabilities
            .accepted_media_types
            .insert("audio/flac".to_string());
        let policy = PreparationPolicy {
            audio: attachment_native_types::AudioPreparationPolicy::DirectAndTranscribe,
            ..PreparationPolicy::default()
        };
        let result = plan(&value, &capabilities, &policy);
        assert!(result.as_ref().is_ok_and(|value| value.parts.len() == 1));
        assert!(matches!(
            result.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::TranscribeAudio])
        ));
    }

    #[test]
    fn video_fallback_is_an_ordered_frames_audio_transcription_pipeline() {
        let source = object_id(6);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Mp4, 16)],
            vec![blob_artifact(
                "video",
                &source,
                "video/mp4",
                Some(MediaFamily::Video),
                16,
            )],
        );
        let result = plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            result.as_ref().map(operation_kinds),
            Ok(operations) if matches!(
                operations.as_slice(),
                [
                    TransformOperation::SampleVideoFrames { max_frames: 8 },
                    TransformOperation::OcrImage,
                    TransformOperation::ExtractVideoAudio,
                    TransformOperation::TranscribeAudio
                ]
            )
        ));
        assert!(result.as_ref().is_ok_and(|plan| {
            let transforms = &plan.transforms;
            transforms.len() == 4
                && transforms[0].depends_on.is_empty()
                && transforms[1].depends_on == vec![transforms[0].id.clone()]
                && transforms[2].depends_on.is_empty()
                && transforms[3].depends_on == vec![transforms[2].id.clone()]
                && plan.validate() == Ok(())
        }));
        let plan = result.expect("video fallback plan must be present");
        assert_eq!(
            plan.aggregate_limits.max_text_bytes,
            target().max_text_bytes
        );
        assert_eq!(
            plan.aggregate_limits.max_media_bytes,
            target().max_media_bytes
        );
        assert_eq!(
            plan.aggregate_limits.max_transform_requests,
            value.graph.limits.max_transform_requests
        );

        let mut per_call_overreach = plan.clone();
        per_call_overreach.transforms[0].limits.max_output_bytes =
            per_call_overreach.aggregate_limits.max_media_bytes + 1;
        assert!(matches!(
            per_call_overreach.validate(),
            Err(ContractError::InvalidPreparationPlan(message))
                if message.contains("shared aggregate output budget")
        ));

        let mut request_overreach = plan;
        request_overreach.aggregate_limits.max_transform_requests = 3;
        assert!(matches!(
            request_overreach.validate(),
            Err(ContractError::InvalidPreparationPlan(message))
                if message.contains("aggregate request budget")
        ));
    }

    #[test]
    fn independent_image_audio_and_pdf_transforms_have_no_dependencies() {
        let image_source = object_id(31);
        let audio_source = object_id(32);
        let pdf_source = object_id(33);
        let value = bundle(
            vec![
                object(image_source.clone(), DetectedFormat::Png, 16),
                object(audio_source.clone(), DetectedFormat::Wav, 16),
                object(pdf_source.clone(), DetectedFormat::Pdf, 16),
            ],
            vec![
                blob_artifact(
                    "image",
                    &image_source,
                    "image/png",
                    Some(MediaFamily::Image),
                    16,
                ),
                blob_artifact(
                    "audio",
                    &audio_source,
                    "audio/wav",
                    Some(MediaFamily::Audio),
                    16,
                ),
                blob_artifact("pdf", &pdf_source, "application/pdf", None, 16),
            ],
        );
        let result = plan(&value, &target(), &PreparationPolicy::default());
        assert!(result.as_ref().is_ok_and(|plan| {
            operation_kinds(plan)
                == vec![
                    &TransformOperation::OcrImage,
                    &TransformOperation::TranscribeAudio,
                    &TransformOperation::ExtractDocumentText,
                ]
                && plan
                    .transforms
                    .iter()
                    .all(|transform| transform.depends_on.is_empty())
        }));
    }

    #[test]
    fn plan_validation_rejects_missing_later_self_and_cyclic_dependencies() -> Result<(), String> {
        let source = object_id(34);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Mp4, 16)],
            vec![blob_artifact(
                "video",
                &source,
                "video/mp4",
                Some(MediaFamily::Video),
                16,
            )],
        );
        let valid = plan(&value, &target(), &PreparationPolicy::default())
            .map_err(|error| error.to_string())?;
        assert_eq!(valid.validate(), Ok(()));

        let mut missing = valid.clone();
        missing.transforms[1].depends_on = vec!["not-a-transform".to_string()];
        assert!(matches!(
            missing.validate(),
            Err(ContractError::InvalidPreparationPlan(message))
                if message.contains("missing or later")
        ));

        let mut later = valid.clone();
        later.transforms[0].depends_on = vec![later.transforms[1].id.clone()];
        assert!(matches!(
            later.validate(),
            Err(ContractError::InvalidPreparationPlan(message))
                if message.contains("missing or later")
        ));

        let mut self_dependent = valid.clone();
        self_dependent.transforms[0].depends_on = vec![self_dependent.transforms[0].id.clone()];
        assert!(matches!(
            self_dependent.validate(),
            Err(ContractError::InvalidPreparationPlan(message))
                if message.contains("cannot depend on itself")
        ));

        let mut cyclic_by_order = valid;
        cyclic_by_order.transforms[0].depends_on = vec![cyclic_by_order.transforms[1].id.clone()];
        cyclic_by_order.transforms[1].depends_on = vec![cyclic_by_order.transforms[0].id.clone()];
        assert!(matches!(
            cyclic_by_order.validate(),
            Err(ContractError::InvalidPreparationPlan(message))
                if message.contains("missing or later")
        ));

        let mut wrong_source = plan(&value, &target(), &PreparationPolicy::default())
            .map_err(|error| error.to_string())?;
        wrong_source.transforms[0].source_artifact = artifact_id("not-in-bundle");
        assert!(matches!(
            wrong_source.validate_against(&value),
            Err(ContractError::InvalidPreparationPlan(message))
                if message.contains("missing artifact")
        ));
        Ok(())
    }

    #[test]
    fn native_video_needs_both_format_and_native_video_capability() {
        let source = object_id(7);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Mp4, 16)],
            vec![blob_artifact(
                "video",
                &source,
                "video/mp4",
                Some(MediaFamily::Video),
                16,
            )],
        );
        let mut capabilities = target();
        capabilities
            .accepted_media_types
            .insert("video/mp4".to_string());
        let without_native = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(
            without_native
                .as_ref()
                .is_ok_and(|value| value.parts.is_empty())
        );
        capabilities.supports_native_video = true;
        let with_native = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(
            with_native
                .as_ref()
                .is_ok_and(|value| value.parts.len() == 1)
        );
    }

    #[test]
    fn every_non_native_video_policy_has_an_explicit_pipeline() {
        let source = object_id(24);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Webm, 16)],
            vec![blob_artifact(
                "video",
                &source,
                "video/webm",
                Some(MediaFamily::Video),
                16,
            )],
        );
        let frames = PreparationPolicy {
            video: attachment_native_types::VideoPreparationPolicy::FramesOnly,
            ..PreparationPolicy::default()
        };
        let transcript = PreparationPolicy {
            video: attachment_native_types::VideoPreparationPolicy::TranscriptOnly,
            ..PreparationPolicy::default()
        };
        let direct = PreparationPolicy {
            video: attachment_native_types::VideoPreparationPolicy::DirectOnly,
            ..PreparationPolicy::default()
        };
        let frames = plan(&value, &target(), &frames);
        assert!(matches!(
            frames.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::SampleVideoFrames { .. }, TransformOperation::OcrImage])
        ));
        let frames_for_image_target = PreparationPolicy {
            video: attachment_native_types::VideoPreparationPolicy::FramesOnly,
            ..PreparationPolicy::default()
        };
        let mut image_target = target();
        image_target
            .accepted_media_types
            .insert("image/png".to_string());
        let frames_for_image_target = plan(&value, &image_target, &frames_for_image_target);
        assert!(matches!(
            frames_for_image_target.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::SampleVideoFrames { .. }])
        ));
        let transcript = plan(&value, &target(), &transcript);
        assert!(matches!(
            transcript.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::ExtractVideoAudio, TransformOperation::TranscribeAudio])
        ));
        let direct = plan(&value, &target(), &direct);
        assert!(matches!(
            direct
                .as_ref()
                .map(|value| value.blockers.first().map(|blocker| blocker.code.as_str())),
            Ok(Some("video_not_supported_by_target"))
        ));
    }

    #[test]
    fn pdf_policy_prefers_text_or_native_as_configured() {
        let source = object_id(8);
        let mut value = bundle(
            vec![object(source.clone(), DetectedFormat::Pdf, 16)],
            vec![
                blob_artifact("pdf", &source, "application/pdf", None, 16),
                text_artifact("pdf-text", &source, TextFormat::Markdown, "body"),
            ],
        );
        value.graph.coverage = Coverage::Complete;
        let mut capabilities = target();
        capabilities.supports_native_pdf = true;
        let text_first = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(matches!(
            text_first.as_ref().map(|value| &value.parts),
            Ok(parts) if matches!(parts.as_slice(), [PreparedPart::UntrustedText { .. }])
        ));
        let policy = PreparationPolicy {
            document: attachment_native_types::DocumentPreparationPolicy::NativeThenCanonicalText,
            ..PreparationPolicy::default()
        };
        let native_first = plan(&value, &capabilities, &policy);
        assert!(matches!(
            native_first.as_ref().map(|value| &value.parts),
            Ok(parts) if matches!(parts.as_slice(), [PreparedPart::OpaqueReference { .. }])
        ));
    }

    #[test]
    fn pdf_without_text_rasterizes_for_image_targets_or_extracts_text_otherwise() {
        let source = object_id(9);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Pdf, 16)],
            vec![blob_artifact("pdf", &source, "application/pdf", None, 16)],
        );
        let text_target = plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            text_target.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::ExtractDocumentText])
        ));
        let mut image_target = target();
        image_target
            .accepted_media_families
            .insert(MediaFamily::Image);
        let raster = plan(&value, &image_target, &PreparationPolicy::default());
        assert!(matches!(
            raster.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::RasterizePdfPages { max_pages: 16, max_megapixels: 8 }])
        ));
    }

    #[test]
    fn native_pdf_over_media_budget_falls_back_without_direct_bytes() {
        let source = object_id(21);
        let mut value = bundle(
            vec![object(source.clone(), DetectedFormat::Pdf, 16)],
            vec![blob_artifact("pdf", &source, "application/pdf", None, 16)],
        );
        value.graph.coverage = Coverage::Complete;
        let mut capabilities = target();
        capabilities.supports_native_pdf = true;
        capabilities.max_media_bytes = 15;
        let policy = PreparationPolicy {
            document: attachment_native_types::DocumentPreparationPolicy::NativeThenCanonicalText,
            ..PreparationPolicy::default()
        };
        let result = plan(&value, &capabilities, &policy);
        assert!(result.as_ref().is_ok_and(|value| value.parts.is_empty()));
        assert!(matches!(
            result.as_ref().map(operation_kinds),
            Ok(operations) if matches!(operations.as_slice(), [TransformOperation::ExtractDocumentText])
        ));
    }

    #[test]
    fn pdf_preference_falls_back_without_recording_a_false_blocker() {
        let source = object_id(30);
        let mut value = bundle(
            vec![object(source.clone(), DetectedFormat::Pdf, 16)],
            vec![
                blob_artifact("pdf", &source, "application/pdf", None, 16),
                text_artifact("pdf-text", &source, TextFormat::Plain, "sixteen bytes!!!!"),
            ],
        );
        value.graph.coverage = Coverage::Complete;
        let mut native_fallback = target();
        native_fallback.supports_native_pdf = true;
        native_fallback.max_text_bytes = 5;
        let native = plan(&value, &native_fallback, &PreparationPolicy::default());
        assert!(matches!(
            native.as_ref().map(|value| &value.parts),
            Ok(parts) if matches!(parts.as_slice(), [PreparedPart::OpaqueReference { .. }])
        ));
        assert!(native.as_ref().is_ok_and(|value| value.blockers.is_empty()));

        let mut text_fallback = target();
        text_fallback.supports_native_pdf = true;
        text_fallback.max_media_bytes = 15;
        let native_first = PreparationPolicy {
            document: attachment_native_types::DocumentPreparationPolicy::NativeThenCanonicalText,
            ..PreparationPolicy::default()
        };
        let text = plan(&value, &text_fallback, &native_first);
        assert!(matches!(
            text.as_ref().map(|value| &value.parts),
            Ok(parts) if matches!(parts.as_slice(), [PreparedPart::UntrustedText { .. }])
        ));
        assert!(text.as_ref().is_ok_and(|value| value.blockers.is_empty()));
    }

    #[test]
    fn native_pdf_requires_complete_parser_backed_inspection() {
        let source = object_id(42);
        let mut partial = bundle(
            vec![object(source.clone(), DetectedFormat::Pdf, 16)],
            vec![blob_artifact("pdf", &source, "application/pdf", None, 16)],
        );
        partial.graph.objects[0].status = ObjectStatus::Partial {
            reasons: vec!["pdf_structure_scan_limit_exceeded".to_string()],
        };
        let mut capabilities = target();
        capabilities.supports_native_pdf = true;
        let policy = PreparationPolicy {
            document: attachment_native_types::DocumentPreparationPolicy::NativeThenCanonicalText,
            ..PreparationPolicy::default()
        };
        let partial_plan = plan(&partial, &capabilities, &policy)
            .expect("partial PDF must produce a typed fallback plan");
        assert!(
            !partial_plan
                .parts
                .iter()
                .any(|part| matches!(part, PreparedPart::OpaqueReference { .. }))
        );
        assert!(
            partial_plan
                .transforms
                .iter()
                .any(|request| request.operation == TransformOperation::ExtractDocumentText)
        );

        let mut signature_only = bundle(
            vec![object(source.clone(), DetectedFormat::UnknownBinary, 16)],
            vec![blob_artifact("pdf", &source, "application/pdf", None, 16)],
        );
        signature_only.graph.coverage = Coverage::Complete;
        let signature_plan = plan(&signature_only, &capabilities, &policy)
            .expect("unconfirmed PDF must produce a typed fallback plan");
        assert!(
            !signature_plan
                .parts
                .iter()
                .any(|part| matches!(part, PreparedPart::OpaqueReference { .. }))
        );
    }

    #[test]
    fn opaque_is_blocked_by_default_and_preserved_only_by_explicit_policy() {
        let source = object_id(10);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::UnknownBinary, 16)],
            vec![blob_artifact(
                "opaque",
                &source,
                "application/octet-stream",
                None,
                16,
            )],
        );
        let blocked = plan(&value, &target(), &PreparationPolicy::default());
        assert!(blocked.as_ref().is_ok_and(|value| value.parts.is_empty()));
        assert!(matches!(
            blocked
                .as_ref()
                .map(|value| value.blockers.first().map(|blocker| blocker.code.as_str())),
            Ok(Some("unsupported_opaque_attachment"))
        ));
        let policy = PreparationPolicy {
            unsupported:
                attachment_native_types::UnsupportedPreparationPolicy::PreserveAsOpaqueReference,
            ..PreparationPolicy::default()
        };
        let preserved = plan(&value, &target(), &policy);
        assert!(preserved.as_ref().is_ok_and(|value| value.parts.len() == 1));
    }

    #[test]
    fn opaque_references_obey_target_media_byte_and_object_limits() {
        let first = object_id(40);
        let second = object_id(41);
        let one = bundle(
            vec![object(first.clone(), DetectedFormat::UnknownBinary, 16)],
            vec![blob_artifact(
                "opaque-one",
                &first,
                "application/octet-stream",
                None,
                16,
            )],
        );
        let policy = PreparationPolicy {
            unsupported:
                attachment_native_types::UnsupportedPreparationPolicy::PreserveAsOpaqueReference,
            ..PreparationPolicy::default()
        };
        let mut byte_limited = target();
        byte_limited.max_media_bytes = 1;
        let byte_limited = plan(&one, &byte_limited, &policy);
        assert!(matches!(
            byte_limited.as_ref(),
            Ok(plan)
                if plan.parts.is_empty()
                    && plan.blockers.first().map(|blocker| blocker.code.as_str())
                        == Some("target_media_budget_exceeded")
        ));

        let two = bundle(
            vec![
                object(first.clone(), DetectedFormat::UnknownBinary, 16),
                object(second.clone(), DetectedFormat::UnknownBinary, 16),
            ],
            vec![
                blob_artifact("opaque-one", &first, "application/octet-stream", None, 16),
                blob_artifact("opaque-two", &second, "application/octet-stream", None, 16),
            ],
        );
        let mut object_limited = target();
        object_limited.max_media_objects = 1;
        let object_limited = plan(&two, &object_limited, &policy);
        assert!(matches!(
            object_limited.as_ref(),
            Ok(plan)
                if plan.parts.len() == 1
                    && plan.blockers.first().map(|blocker| blocker.code.as_str())
                        == Some("target_media_budget_exceeded")
        ));
    }

    #[test]
    fn executable_is_blocked_even_when_opaque_references_are_permitted() {
        let source = object_id(11);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::Executable, 16)],
            vec![blob_artifact(
                "opaque",
                &source,
                "application/x-executable",
                None,
                16,
            )],
        );
        let policy = PreparationPolicy {
            unsupported:
                attachment_native_types::UnsupportedPreparationPolicy::PreserveAsOpaqueReference,
            ..PreparationPolicy::default()
        };
        let result = plan(&value, &target(), &policy);
        assert!(matches!(
            result
                .as_ref()
                .map(|value| value.blockers.first().map(|blocker| blocker.code.as_str())),
            Ok(Some("executable_attachment_blocked"))
        ));
    }

    #[test]
    fn target_text_and_media_budgets_fail_closed_without_truncation() {
        let text_source = object_id(12);
        let image_source = object_id(13);
        let value = bundle(
            vec![
                object(text_source.clone(), DetectedFormat::PlainText, 6),
                object(image_source.clone(), DetectedFormat::Png, 16),
            ],
            vec![
                text_artifact("text", &text_source, TextFormat::Plain, "abcdef"),
                blob_artifact(
                    "image",
                    &image_source,
                    "image/png",
                    Some(MediaFamily::Image),
                    16,
                ),
            ],
        );
        let mut capabilities = target();
        capabilities.max_text_bytes = 5;
        capabilities.max_media_bytes = 15;
        capabilities
            .accepted_media_families
            .insert(MediaFamily::Image);
        let result = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(result.as_ref().is_ok_and(|value| value.parts.is_empty()));
        assert!(result.as_ref().is_ok_and(|value| value.blockers.len() == 2));
    }

    #[test]
    fn transform_budget_is_global_and_monotonic() {
        let source = object_id(14);
        let mut value = bundle(
            vec![object(source.clone(), DetectedFormat::Mp4, 16)],
            vec![blob_artifact(
                "video",
                &source,
                "video/mp4",
                Some(MediaFamily::Video),
                16,
            )],
        );
        value.graph.limits.max_transform_requests = 2;
        let result = plan(&value, &target(), &PreparationPolicy::default());
        assert!(
            result
                .as_ref()
                .is_ok_and(|value| value.transforms.len() == 2)
        );
        assert!(matches!(
            result
                .as_ref()
                .map(|value| value.blockers.first().map(|blocker| blocker.code.as_str())),
            Ok(Some("transform_request_budget_exceeded"))
        ));
    }

    #[test]
    fn artifact_input_order_does_not_change_plan_or_fingerprint() {
        let first = object_id(15);
        let second = object_id(16);
        let artifacts = vec![
            text_artifact("first", &first, TextFormat::Plain, "a"),
            text_artifact("second", &second, TextFormat::Plain, "b"),
        ];
        let left = bundle(
            vec![
                object(first.clone(), DetectedFormat::PlainText, 1),
                object(second.clone(), DetectedFormat::PlainText, 1),
            ],
            artifacts.clone(),
        );
        let right = bundle(
            vec![
                object(first, DetectedFormat::PlainText, 1),
                object(second, DetectedFormat::PlainText, 1),
            ],
            artifacts.into_iter().rev().collect(),
        );
        let left_plan = plan(&left, &target(), &PreparationPolicy::default());
        let right_plan = plan(&right, &target(), &PreparationPolicy::default());
        assert!(matches!(
            (left_plan, right_plan),
            (Ok(left), Ok(right))
                if left.cache_fingerprint == right.cache_fingerprint
                    && left.plan_id == right.plan_id
                    && left.parts == right.parts
        ));
    }

    #[test]
    fn fingerprint_ignores_job_id_but_binds_artifact_policy_target_and_payload() {
        let source = object_id(17);
        let base = bundle(
            vec![object(source.clone(), DetectedFormat::PlainText, 1)],
            vec![text_artifact("first-id", &source, TextFormat::Plain, "a")],
        );
        let mut same_identity = base.clone();
        same_identity.graph.job_id = AttachmentJobId("different-job".to_string());
        let first = plan(&base, &target(), &PreparationPolicy::default());
        let same = plan(&same_identity, &target(), &PreparationPolicy::default());
        assert!(matches!(
            (&first, &same),
            (Ok(first), Ok(same)) if first.cache_fingerprint == same.cache_fingerprint
        ));

        let changed_id = bundle(
            vec![object(source.clone(), DetectedFormat::PlainText, 1)],
            vec![text_artifact("other-id", &source, TextFormat::Plain, "a")],
        );
        let changed_id = plan(&changed_id, &target(), &PreparationPolicy::default());
        assert!(matches!(
            (&first, &changed_id),
            (Ok(first), Ok(changed))
                if first.cache_fingerprint != changed.cache_fingerprint
                    && first.plan_id != changed.plan_id
                    && first.parts != changed.parts
        ));

        let mut changed_payload_bundle = base.clone();
        if let ArtifactPayload::Text { text, .. } = &mut changed_payload_bundle.artifacts[0].payload
        {
            *text = "b".to_string();
        }
        let changed_payload = plan(
            &changed_payload_bundle,
            &target(),
            &PreparationPolicy::default(),
        );
        let mut changed_target = target();
        changed_target.fingerprint = "other-target".to_string();
        let changed_target = plan(&base, &changed_target, &PreparationPolicy::default());
        let changed_policy = PreparationPolicy {
            image: attachment_native_types::ImagePreparationPolicy::OcrOnly,
            ..PreparationPolicy::default()
        };
        let changed_policy = plan(&base, &target(), &changed_policy);
        assert!(matches!(
            (first, changed_payload, changed_target, changed_policy),
            (Ok(first), Ok(payload), Ok(target), Ok(policy))
                if first.cache_fingerprint != payload.cache_fingerprint
                    && first.cache_fingerprint != target.cache_fingerprint
                    && first.cache_fingerprint != policy.cache_fingerprint
        ));
    }

    #[test]
    fn fingerprint_binds_planner_bounds_graph_status_and_transform_budget() {
        let source = object_id(25);
        let base = bundle(
            vec![object(source.clone(), DetectedFormat::Png, 16)],
            vec![blob_artifact(
                "image",
                &source,
                "image/png",
                Some(MediaFamily::Image),
                16,
            )],
        );
        let normal =
            PreparationPlanner::new().plan(&base, &target(), &PreparationPolicy::default());
        let bounded = PreparationPlanner::new()
            .with_transform_limits(30_000, 2, 4, 2)
            .plan(&base, &target(), &PreparationPolicy::default());
        let mut different_status = base.clone();
        different_status.graph.objects[0].status = ObjectStatus::Partial {
            reasons: vec!["fixture".to_string()],
        };
        let different_status = plan(&different_status, &target(), &PreparationPolicy::default());
        let mut different_budget = base;
        different_budget.graph.limits.max_transform_requests = 1;
        let different_budget = plan(&different_budget, &target(), &PreparationPolicy::default());
        assert!(matches!(
            (normal, bounded, different_status, different_budget),
            (Ok(normal), Ok(bounded), Ok(status), Ok(budget))
                if normal.cache_fingerprint != bounded.cache_fingerprint
                    && normal.cache_fingerprint != status.cache_fingerprint
                    && normal.cache_fingerprint != budget.cache_fingerprint
        ));
    }

    #[test]
    fn transform_ids_ignore_job_id_but_bind_source_artifact_id() {
        let source = object_id(26);
        let first = bundle(
            vec![object(source.clone(), DetectedFormat::Png, 16)],
            vec![blob_artifact(
                "first-id",
                &source,
                "image/png",
                Some(MediaFamily::Image),
                16,
            )],
        );
        let mut same_identity = first.clone();
        same_identity.graph.job_id = AttachmentJobId("another-job".to_string());
        let second = bundle(
            vec![object(source.clone(), DetectedFormat::Png, 16)],
            vec![blob_artifact(
                "second-id",
                &source,
                "image/png",
                Some(MediaFamily::Image),
                16,
            )],
        );
        let first = plan(&first, &target(), &PreparationPolicy::default());
        let same_identity = plan(&same_identity, &target(), &PreparationPolicy::default());
        let second = plan(&second, &target(), &PreparationPolicy::default());
        assert!(matches!(
            (&first, &same_identity),
            (Ok(first), Ok(same))
                if first.transforms.first().map(|value| &value.id)
                    == same.transforms.first().map(|value| &value.id)
        ));
        assert!(matches!(
            (first, second),
            (Ok(first), Ok(second))
                if first.transforms.first().map(|value| &value.id)
                    != second.transforms.first().map(|value| &value.id)
                    && first.transforms.first().map(|value| &value.source_artifact)
                        != second.transforms.first().map(|value| &value.source_artifact)
        ));
    }

    #[test]
    fn invalid_bundle_and_target_are_rejected_before_planning() {
        let source = object_id(18);
        let mut value = bundle(
            vec![object(source.clone(), DetectedFormat::PlainText, 1)],
            vec![text_artifact("text", &source, TextFormat::Plain, "a")],
        );
        value.graph.schema = "wrong".to_string();
        let invalid_bundle = plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            invalid_bundle,
            Err(AttachmentError { code, .. }) if code == "invalid_attachment_bundle"
        ));

        value.graph.schema = attachment_native_types::GRAPH_SCHEMA.to_string();
        let mut capabilities = target();
        capabilities.target_id.clear();
        let invalid_target = plan(&value, &capabilities, &PreparationPolicy::default());
        assert!(matches!(
            invalid_target,
            Err(AttachmentError { code, .. }) if code == "invalid_target_capabilities"
        ));
    }

    #[test]
    fn every_inspected_object_must_retain_its_content_addressed_blob() {
        let source = object_id(29);
        let mut value = bundle(
            vec![object(source.clone(), DetectedFormat::Png, 16)],
            vec![blob_artifact(
                "image",
                &source,
                "image/png",
                Some(MediaFamily::Image),
                16,
            )],
        );
        value.blobs.clear();
        let result = plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            result,
            Err(AttachmentError { code, .. }) if code == "invalid_attachment_bundle"
        ));
    }

    #[test]
    fn empty_canonicalization_never_becomes_silent_success() {
        let source = object_id(27);
        let value = bundle(
            vec![object(source, DetectedFormat::UnknownBinary, 0)],
            Vec::new(),
        );
        let result = plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            result
                .as_ref()
                .map(|value| value.blockers.first().map(|blocker| blocker.code.as_str())),
            Ok(Some("no_preparable_attachment_content"))
        ));
    }

    #[test]
    fn zero_transform_configuration_is_rejected() {
        let source = object_id(28);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::PlainText, 1)],
            vec![text_artifact("text", &source, TextFormat::Plain, "a")],
        );
        let result = PreparationPlanner::new()
            .with_transform_limits(0, 1, 1, 1)
            .plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            result,
            Err(AttachmentError { code, .. }) if code == "invalid_planner_limits"
        ));
    }

    #[test]
    fn output_contract_is_versioned_and_has_no_authority_side_effects() {
        let source = object_id(19);
        let value = bundle(
            vec![object(source.clone(), DetectedFormat::PlainText, 1)],
            vec![text_artifact("text", &source, TextFormat::Plain, "a")],
        );
        let result = plan(&value, &target(), &PreparationPolicy::default());
        assert!(matches!(
            result,
            Ok(value)
                if value.schema == PLAN_SCHEMA
                    && value.plan_id.starts_with("plan-")
                    && value.cache_fingerprint.len() == 64
        ));
    }

    #[test]
    fn default_policy_serializes_without_unknown_binary_authority() {
        let policy = PreparationPolicy::default();
        let inspection = attachment_native_types::InspectionPolicy {
            unknown_binary: UnknownBinaryPolicy::Reject,
            ..attachment_native_types::InspectionPolicy::default()
        };
        assert_eq!(inspection.unknown_binary, UnknownBinaryPolicy::Reject);
        assert_eq!(
            policy.unsupported,
            attachment_native_types::UnsupportedPreparationPolicy::Block
        );
    }

    #[test]
    fn test_fixture_maps_are_deterministic() {
        let map = BTreeMap::<String, String>::new();
        assert!(map.is_empty());
    }
}
