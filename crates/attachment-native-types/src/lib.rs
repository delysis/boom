#![forbid(unsafe_code)]

//! Versioned, protocol-neutral contracts for inspecting hostile attachment
//! bytes and preparing the resulting artifacts for an exact model capability.
//!
//! These types intentionally grant no filesystem, network, process, UI, or
//! model authority.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;
use std::sync::Arc;
use thiserror::Error;
use uuid::Uuid;

pub const GRAPH_SCHEMA: &str = "attachment_native.graph.v1";
pub const ARTIFACT_SCHEMA: &str = "attachment_native.artifact.v2";
pub const PLAN_SCHEMA: &str = "attachment_native.preparation_plan.v2";
pub const RECEIPT_SCHEMA: &str = "attachment_native.receipt.v1";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash, Ord, PartialOrd)]
#[serde(transparent)]
pub struct ObjectId(pub String);

impl fmt::Display for ObjectId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash, Ord, PartialOrd)]
#[serde(transparent)]
pub struct ArtifactId(pub String);

impl ArtifactId {
    #[must_use]
    pub fn new() -> Self {
        Self(Uuid::new_v4().to_string())
    }
}

impl Default for ArtifactId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash, Ord, PartialOrd)]
#[serde(transparent)]
pub struct AttachmentJobId(pub String);

impl AttachmentJobId {
    #[must_use]
    pub fn new() -> Self {
        Self(Uuid::new_v4().to_string())
    }
}

impl Default for AttachmentJobId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct InspectionPolicy {
    pub limits: BudgetLimits,
    #[serde(default)]
    pub unknown_binary: UnknownBinaryPolicy,
    #[serde(default)]
    pub path_policy: ArchivePathPolicy,
    #[serde(default = "default_true")]
    pub analyze_duplicate_content_once: bool,
    #[serde(default = "default_true")]
    pub continue_after_child_error: bool,
    #[serde(default = "default_true")]
    pub inspect_pdf_embedded_files: bool,
}

impl Default for InspectionPolicy {
    fn default() -> Self {
        Self {
            limits: BudgetLimits::default(),
            unknown_binary: UnknownBinaryPolicy::RecordOpaque,
            path_policy: ArchivePathPolicy::SanitizeAndScan,
            analyze_duplicate_content_once: true,
            continue_after_child_error: true,
            inspect_pdf_embedded_files: true,
        }
    }
}

impl InspectionPolicy {
    pub fn validate(&self) -> Result<(), ContractError> {
        self.limits.validate()
    }
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UnknownBinaryPolicy {
    Reject,
    #[default]
    RecordOpaque,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ArchivePathPolicy {
    RejectEntry,
    #[default]
    SanitizeAndScan,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct BudgetLimits {
    pub max_root_bytes: u64,
    pub max_object_bytes: u64,
    pub max_total_derived_bytes: u64,
    pub max_retained_bytes: u64,
    pub max_objects: u32,
    pub max_edges: u32,
    pub max_entries: u32,
    pub max_depth: u16,
    pub max_name_bytes: u32,
    /// Maximum retained input passed in one call to a structured container or
    /// document parser. Streaming decompressors use their output budgets
    /// instead.
    pub max_parser_input_bytes: u64,
    /// Maximum encoded directory/index metadata accepted from one container
    /// before a third-party parser is allowed to materialize its entry table.
    pub max_container_metadata_bytes: u64,
    /// Maximum history/dictionary window a compressed stream decoder may
    /// allocate from attacker-controlled headers. This is independent of the
    /// decoded-output budget because a tiny stream can request a huge window.
    pub max_decoder_window_bytes: u64,
    pub max_declared_to_actual_ratio: u32,
    pub max_text_bytes: u64,
    pub max_media_objects: u32,
    pub max_media_bytes: u64,
    pub max_image_pixels: u64,
    pub max_transform_requests: u32,
    pub deadline_ms: u64,
}

impl Default for BudgetLimits {
    fn default() -> Self {
        Self {
            max_root_bytes: 256 * 1024 * 1024,
            max_object_bytes: 128 * 1024 * 1024,
            max_total_derived_bytes: 1024 * 1024 * 1024,
            max_retained_bytes: 512 * 1024 * 1024,
            max_objects: 4_096,
            max_edges: 8_192,
            max_entries: 8_192,
            max_depth: 8,
            max_name_bytes: 4_096,
            max_parser_input_bytes: 64 * 1024 * 1024,
            max_container_metadata_bytes: 64 * 1024 * 1024,
            max_decoder_window_bytes: 64 * 1024 * 1024,
            max_declared_to_actual_ratio: 200,
            max_text_bytes: 32 * 1024 * 1024,
            max_media_objects: 128,
            max_media_bytes: 256 * 1024 * 1024,
            max_image_pixels: 40_000_000,
            max_transform_requests: 256,
            deadline_ms: 30_000,
        }
    }
}

impl BudgetLimits {
    pub fn validate(&self) -> Result<(), ContractError> {
        let positive = [
            self.max_root_bytes,
            self.max_object_bytes,
            self.max_total_derived_bytes,
            self.max_retained_bytes,
            self.max_text_bytes,
            self.max_media_bytes,
            self.max_image_pixels,
            self.max_parser_input_bytes,
            self.max_container_metadata_bytes,
            self.max_decoder_window_bytes,
            self.deadline_ms,
        ]
        .into_iter()
        .all(|value| value > 0);
        if !positive
            || self.max_objects == 0
            || self.max_edges == 0
            || self.max_entries == 0
            || self.max_name_bytes == 0
            || self.max_declared_to_actual_ratio == 0
            || self.max_media_objects == 0
            || self.max_transform_requests == 0
        {
            return Err(ContractError::InvalidBudget(
                "all attachment limits except max_depth must be greater than zero".to_string(),
            ));
        }
        if self.max_object_bytes > self.max_total_derived_bytes {
            return Err(ContractError::InvalidBudget(
                "max_object_bytes cannot exceed max_total_derived_bytes".to_string(),
            ));
        }
        if self.max_root_bytes > self.max_retained_bytes {
            return Err(ContractError::InvalidBudget(
                "max_root_bytes cannot exceed max_retained_bytes".to_string(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct BudgetUsage {
    pub root_bytes: u64,
    pub total_derived_bytes: u64,
    pub retained_bytes: u64,
    pub objects: u32,
    pub edges: u32,
    pub entries: u32,
    pub deepest_object: u16,
    pub text_bytes: u64,
    pub media_objects: u32,
    pub media_bytes: u64,
    pub transform_requests: u32,
}

impl BudgetUsage {
    /// Returns true when every monotonic accounting dimension is at least the
    /// corresponding value in an earlier observation.
    #[must_use]
    pub fn dominates(&self, earlier: &Self) -> bool {
        self.root_bytes >= earlier.root_bytes
            && self.total_derived_bytes >= earlier.total_derived_bytes
            && self.retained_bytes >= earlier.retained_bytes
            && self.objects >= earlier.objects
            && self.edges >= earlier.edges
            && self.entries >= earlier.entries
            && self.deepest_object >= earlier.deepest_object
            && self.text_bytes >= earlier.text_bytes
            && self.media_objects >= earlier.media_objects
            && self.media_bytes >= earlier.media_bytes
            && self.transform_requests >= earlier.transform_requests
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AttachmentGraph {
    pub schema: String,
    pub job_id: AttachmentJobId,
    pub root: ObjectId,
    pub root_name: LogicalName,
    pub objects: Vec<ObjectRecord>,
    pub edges: Vec<DerivationEdge>,
    pub issues: Vec<AttachmentIssue>,
    pub coverage: Coverage,
    pub limits: BudgetLimits,
    pub usage: BudgetUsage,
}

impl AttachmentGraph {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.schema != GRAPH_SCHEMA {
            return Err(ContractError::SchemaMismatch {
                expected: GRAPH_SCHEMA.to_string(),
                actual: self.schema.clone(),
            });
        }
        self.limits.validate()?;
        let mut ids = BTreeSet::new();
        for object in &self.objects {
            object.validate()?;
            if !ids.insert(&object.id) {
                return Err(ContractError::DuplicateObject(object.id.to_string()));
            }
        }
        if !ids.contains(&self.root) {
            return Err(ContractError::MissingObject(self.root.to_string()));
        }
        let root = self
            .objects
            .iter()
            .find(|object| object.id == self.root)
            .ok_or_else(|| ContractError::MissingObject(self.root.to_string()))?;
        if root.first_depth != 0 {
            return Err(ContractError::InvalidGraph(
                "the root object must have depth zero".to_string(),
            ));
        }
        if root.byte_len > self.limits.max_root_bytes {
            return Err(ContractError::InvalidGraph(format!(
                "root object length {} exceeds the declared root-byte limit {}",
                root.byte_len, self.limits.max_root_bytes
            )));
        }
        for object in self.objects.iter().filter(|object| object.id != self.root) {
            if object.first_depth == 0 {
                return Err(ContractError::InvalidGraph(format!(
                    "non-root object {} cannot have depth zero",
                    object.id
                )));
            }
            if object.first_depth > self.limits.max_depth {
                return Err(ContractError::DepthOutOfRange(object.first_depth));
            }
            if object.byte_len > self.limits.max_object_bytes {
                return Err(ContractError::InvalidGraph(format!(
                    "derived object {} length {} exceeds the declared per-object limit {}",
                    object.id, object.byte_len, self.limits.max_object_bytes
                )));
            }
        }
        if self.usage.root_bytes != root.byte_len {
            return Err(ContractError::InvalidGraph(format!(
                "root byte usage {} does not match the root object length {}",
                self.usage.root_bytes, root.byte_len
            )));
        }

        let object_count =
            u32::try_from(self.objects.len()).map_err(|_| ContractError::IntegerOverflow)?;
        let edge_count =
            u32::try_from(self.edges.len()).map_err(|_| ContractError::IntegerOverflow)?;
        if self.usage.objects != object_count || self.usage.edges != edge_count {
            return Err(ContractError::InvalidGraph(format!(
                "usage counts ({}, {} objects/edges) do not match graph counts ({object_count}, {edge_count})",
                self.usage.objects, self.usage.edges
            )));
        }
        let minimum_derived_bytes = self
            .objects
            .iter()
            .filter(|object| object.id != self.root)
            .try_fold(0_u64, |total, object| {
                total
                    .checked_add(object.byte_len)
                    .ok_or(ContractError::IntegerOverflow)
            })?;
        if self.usage.total_derived_bytes < minimum_derived_bytes {
            return Err(ContractError::InvalidGraph(format!(
                "derived-byte usage {} is smaller than the {minimum_derived_bytes} bytes retained by derived objects",
                self.usage.total_derived_bytes
            )));
        }
        validate_usage(&self.usage, &self.limits)?;

        let objects_by_id = self
            .objects
            .iter()
            .map(|object| (&object.id, object))
            .collect::<BTreeMap<_, _>>();
        for edge in &self.edges {
            if edge.transform.implementation.trim().is_empty()
                || edge.transform.version.trim().is_empty()
            {
                return Err(ContractError::InvalidGraph(
                    "derivation-edge implementation and version provenance must not be empty"
                        .to_string(),
                ));
            }
            if !ids.contains(&edge.parent) {
                return Err(ContractError::MissingObject(edge.parent.to_string()));
            }
            if let Some(child) = &edge.child
                && !ids.contains(child)
            {
                return Err(ContractError::MissingObject(child.to_string()));
            }
            if edge.depth > self.limits.max_depth.saturating_add(1)
                || (edge.depth > self.limits.max_depth
                    && !matches!(edge.outcome, EdgeOutcome::DepthExceeded))
            {
                return Err(ContractError::DepthOutOfRange(edge.depth));
            }
            let parent = objects_by_id
                .get(&edge.parent)
                .ok_or_else(|| ContractError::MissingObject(edge.parent.to_string()))?;
            if edge.depth != parent.first_depth.saturating_add(1) {
                return Err(ContractError::InvalidGraph(format!(
                    "edge from {} has depth {}, expected {}",
                    edge.parent,
                    edge.depth,
                    parent.first_depth.saturating_add(1)
                )));
            }
            let must_have_child =
                matches!(edge.outcome, EdgeOutcome::Derived | EdgeOutcome::Duplicate);
            if must_have_child != edge.child.is_some() {
                return Err(ContractError::InvalidGraph(format!(
                    "edge outcome {:?} has an inconsistent child reference",
                    edge.outcome
                )));
            }
            if let Some(child_id) = &edge.child {
                let child = objects_by_id
                    .get(child_id)
                    .ok_or_else(|| ContractError::MissingObject(child_id.to_string()))?;
                match edge.outcome {
                    EdgeOutcome::Derived if child.first_depth != edge.depth => {
                        return Err(ContractError::InvalidGraph(format!(
                            "derived child {} has depth {}, expected {}",
                            child.id, child.first_depth, edge.depth
                        )));
                    }
                    EdgeOutcome::Duplicate if child.first_depth > edge.depth => {
                        return Err(ContractError::InvalidGraph(format!(
                            "duplicate child {} first appears below its referring edge",
                            child.id
                        )));
                    }
                    _ => {}
                }
            }
            if let Some(range) = &edge.source_range
                && range.start > range.end_exclusive
            {
                return Err(ContractError::InvalidGraph(
                    "an edge source range starts after it ends".to_string(),
                ));
            }
            if let Some(range) = &edge.source_range
                && range.end_exclusive > parent.byte_len
            {
                return Err(ContractError::InvalidGraph(format!(
                    "an edge source range ends at {}, beyond parent {} length {}",
                    range.end_exclusive, parent.id, parent.byte_len
                )));
            }
        }

        for object in self.objects.iter().filter(|object| object.id != self.root) {
            let has_derivation = self.edges.iter().any(|edge| {
                matches!(edge.outcome, EdgeOutcome::Derived)
                    && edge.child.as_ref() == Some(&object.id)
            });
            if !has_derivation {
                return Err(ContractError::InvalidGraph(format!(
                    "non-root object {} has no provenance-establishing derived edge",
                    object.id
                )));
            }
        }

        let expected_deepest = self
            .objects
            .iter()
            .map(|object| object.first_depth)
            .chain(self.edges.iter().map(|edge| edge.depth))
            .max()
            .unwrap_or_default();
        if self.usage.deepest_object != expected_deepest {
            return Err(ContractError::InvalidGraph(format!(
                "deepest-object usage {} does not match graph depth {expected_deepest}",
                self.usage.deepest_object
            )));
        }

        let mut reachable = BTreeSet::from([self.root.clone()]);
        let mut queue = VecDeque::from([self.root.clone()]);
        while let Some(parent) = queue.pop_front() {
            for child in self
                .edges
                .iter()
                .filter(|edge| edge.parent == parent)
                .filter_map(|edge| edge.child.as_ref())
            {
                if reachable.insert(child.clone()) {
                    queue.push_back(child.clone());
                }
            }
        }
        if reachable.len() != self.objects.len() {
            return Err(ContractError::InvalidGraph(
                "the object graph contains an object unreachable from the root".to_string(),
            ));
        }

        for issue in &self.issues {
            if issue.code.trim().is_empty() || issue.safe_message.trim().is_empty() {
                return Err(ContractError::InvalidGraph(
                    "issue codes and safe messages must not be empty".to_string(),
                ));
            }
            if let Some(object_id) = &issue.object_id
                && !ids.contains(object_id)
            {
                return Err(ContractError::MissingObject(object_id.to_string()));
            }
            if let Some(edge_index) = issue.edge_index {
                let edge_index =
                    usize::try_from(edge_index).map_err(|_| ContractError::IntegerOverflow)?;
                if edge_index >= self.edges.len() {
                    return Err(ContractError::InvalidGraph(
                        "an issue refers to a missing derivation edge".to_string(),
                    ));
                }
            }
        }

        match &self.coverage {
            Coverage::Complete => {
                if self
                    .objects
                    .iter()
                    .any(|object| !matches!(object.status, ObjectStatus::Complete))
                {
                    return Err(ContractError::InvalidGraph(
                        "complete coverage cannot contain an incomplete object".to_string(),
                    ));
                }
                if self
                    .issues
                    .iter()
                    .any(|issue| matches!(issue.severity, IssueSeverity::Blocked))
                {
                    return Err(ContractError::InvalidGraph(
                        "complete coverage cannot contain a blocked issue".to_string(),
                    ));
                }
                if self.edges.iter().any(|edge| {
                    matches!(
                        edge.outcome,
                        EdgeOutcome::RejectedName
                            | EdgeOutcome::SpecialFile
                            | EdgeOutcome::Encrypted
                            | EdgeOutcome::UnsupportedCodec
                            | EdgeOutcome::Malformed
                            | EdgeOutcome::BudgetExceeded
                            | EdgeOutcome::DepthExceeded
                    )
                }) {
                    return Err(ContractError::InvalidGraph(
                        "complete coverage cannot contain an incomplete derivation outcome"
                            .to_string(),
                    ));
                }
            }
            Coverage::Partial { reasons } if reasons.is_empty() => {
                return Err(ContractError::InvalidGraph(
                    "partial coverage must name at least one reason".to_string(),
                ));
            }
            Coverage::Partial { .. } => {}
        }
        Ok(())
    }
}

fn validate_usage(usage: &BudgetUsage, limits: &BudgetLimits) -> Result<(), ContractError> {
    let within_limits = usage.root_bytes <= limits.max_root_bytes
        && usage.total_derived_bytes <= limits.max_total_derived_bytes
        && usage.retained_bytes <= limits.max_retained_bytes
        && usage.objects <= limits.max_objects
        && usage.edges <= limits.max_edges
        && usage.entries <= limits.max_entries
        && usage.deepest_object <= limits.max_depth.saturating_add(1)
        && usage.text_bytes <= limits.max_text_bytes
        && usage.media_objects <= limits.max_media_objects
        && usage.media_bytes <= limits.max_media_bytes
        && usage.transform_requests <= limits.max_transform_requests;
    if !within_limits {
        return Err(ContractError::InvalidGraph(
            "recorded usage exceeds the graph's declared limits".to_string(),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ObjectRecord {
    pub id: ObjectId,
    pub sha256: String,
    pub byte_len: u64,
    pub detection: Detection,
    pub status: ObjectStatus,
    pub first_depth: u16,
    pub artifact_ids: Vec<ArtifactId>,
}

impl ObjectRecord {
    fn validate(&self) -> Result<(), ContractError> {
        if self.sha256.len() != 64
            || !self
                .sha256
                .bytes()
                .all(|value| value.is_ascii_hexdigit() && !value.is_ascii_uppercase())
        {
            return Err(ContractError::InvalidHash(self.sha256.clone()));
        }
        if self.id.0 != self.sha256 {
            return Err(ContractError::ObjectIdHashMismatch(self.id.to_string()));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DerivationEdge {
    pub parent: ObjectId,
    pub child: Option<ObjectId>,
    pub depth: u16,
    pub name: LogicalName,
    pub transform: TransformProvenance,
    pub declared_uncompressed_bytes: Option<u64>,
    pub compressed_bytes: Option<u64>,
    pub source_range: Option<ByteRange>,
    pub outcome: EdgeOutcome,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LogicalName {
    pub display: String,
    pub raw_name_hex: Option<String>,
    pub sanitized: bool,
}

impl LogicalName {
    #[must_use]
    pub fn provided(display: impl Into<String>) -> Self {
        Self {
            display: display.into(),
            raw_name_hex: None,
            sanitized: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TransformProvenance {
    pub kind: TransformKind,
    pub implementation: String,
    pub version: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TransformKind {
    RootInput,
    ZipMember,
    TarMember,
    GzipPayload,
    Bzip2Payload,
    XzPayload,
    ZstdPayload,
    SevenZipMember,
    RarMember,
    EmbeddedRange,
    DocumentPart,
    EmailPart,
    MailboxMessage,
    PdfEmbeddedFile,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EdgeOutcome {
    Derived,
    Duplicate,
    Directory,
    RejectedName,
    SpecialFile,
    Encrypted,
    UnsupportedCodec,
    Malformed,
    BudgetExceeded,
    DepthExceeded,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ByteRange {
    pub start: u64,
    pub end_exclusive: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Detection {
    pub selected: Option<DetectedFormat>,
    pub candidates: Vec<FormatCandidate>,
    pub extension_hint: Option<String>,
    pub declared_media_type: Option<String>,
    pub mismatch: Option<DetectionMismatch>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DetectionMismatch {
    pub hint: String,
    pub detected: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FormatCandidate {
    pub format: DetectedFormat,
    pub confidence: DetectionConfidence,
    pub evidence: DetectionEvidence,
    pub offset: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DetectionConfidence {
    ParserConfirmed,
    StrongSignature,
    Probable,
    HintOnly,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DetectionEvidence {
    ParserStructure,
    MagicBytes,
    ContainerMembers,
    TextSyntax,
    DeclaredMediaType,
    FileExtension,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash, Ord, PartialOrd)]
#[serde(rename_all = "snake_case")]
pub enum DetectedFormat {
    PlainText,
    Markdown,
    RichText,
    WebVtt,
    SubRip,
    Json,
    Csv,
    Tsv,
    Html,
    Xml,
    Svg,
    JupyterNotebook,
    Pdf,
    Docx,
    Pptx,
    Xlsx,
    Epub,
    OpenDocumentText,
    OpenDocumentSpreadsheet,
    OpenDocumentPresentation,
    IWorkPages,
    IWorkNumbers,
    IWorkKeynote,
    OleCompound,
    Email,
    Mbox,
    Zip,
    Tar,
    Gzip,
    Bzip2,
    Xz,
    Zstd,
    SevenZip,
    Rar,
    Png,
    Jpeg,
    Gif,
    Webp,
    Bmp,
    Tiff,
    Heif,
    Avif,
    Wav,
    Aiff,
    Caf,
    Flac,
    Mp3,
    Ogg,
    OggAudio,
    OggVideo,
    M4a,
    Mp4,
    QuickTime,
    Matroska,
    Webm,
    Avi,
    Executable,
    UnknownBinary,
}

impl DetectedFormat {
    #[must_use]
    pub const fn is_container(self) -> bool {
        matches!(
            self,
            Self::Zip
                | Self::Docx
                | Self::Pptx
                | Self::Xlsx
                | Self::Epub
                | Self::OpenDocumentText
                | Self::OpenDocumentSpreadsheet
                | Self::OpenDocumentPresentation
                | Self::IWorkPages
                | Self::IWorkNumbers
                | Self::IWorkKeynote
                | Self::OleCompound
                | Self::Email
                | Self::Mbox
                | Self::Tar
                | Self::Gzip
                | Self::Bzip2
                | Self::Xz
                | Self::Zstd
                | Self::SevenZip
                | Self::Rar
        )
    }

    #[must_use]
    pub const fn media_family(self) -> Option<MediaFamily> {
        match self {
            Self::Png
            | Self::Jpeg
            | Self::Gif
            | Self::Webp
            | Self::Bmp
            | Self::Tiff
            | Self::Heif
            | Self::Avif
            | Self::Svg => Some(MediaFamily::Image),
            Self::Wav
            | Self::Aiff
            | Self::Caf
            | Self::Flac
            | Self::Mp3
            | Self::OggAudio
            | Self::M4a => Some(MediaFamily::Audio),
            Self::OggVideo
            | Self::Mp4
            | Self::QuickTime
            | Self::Matroska
            | Self::Webm
            | Self::Avi => Some(MediaFamily::Video),
            _ => None,
        }
    }

    #[must_use]
    pub const fn canonical_media_type(self) -> &'static str {
        match self {
            Self::PlainText => "text/plain",
            Self::Markdown => "text/markdown",
            Self::RichText => "application/rtf",
            Self::WebVtt => "text/vtt",
            Self::SubRip => "application/x-subrip",
            Self::Json => "application/json",
            Self::Csv => "text/csv",
            Self::Tsv => "text/tab-separated-values",
            Self::Html => "text/html",
            Self::Xml => "application/xml",
            Self::Svg => "image/svg+xml",
            Self::JupyterNotebook => "application/x-ipynb+json",
            Self::Pdf => "application/pdf",
            Self::Docx => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            Self::Pptx => {
                "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            }
            Self::Xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            Self::Epub => "application/epub+zip",
            Self::OpenDocumentText => "application/vnd.oasis.opendocument.text",
            Self::OpenDocumentSpreadsheet => "application/vnd.oasis.opendocument.spreadsheet",
            Self::OpenDocumentPresentation => "application/vnd.oasis.opendocument.presentation",
            Self::IWorkPages => "application/vnd.apple.pages",
            Self::IWorkNumbers => "application/vnd.apple.numbers",
            Self::IWorkKeynote => "application/vnd.apple.keynote",
            Self::OleCompound => "application/x-ole-storage",
            Self::Email => "message/rfc822",
            Self::Mbox => "application/mbox",
            Self::Zip => "application/zip",
            Self::Tar => "application/x-tar",
            Self::Gzip => "application/gzip",
            Self::Bzip2 => "application/x-bzip2",
            Self::Xz => "application/x-xz",
            Self::Zstd => "application/zstd",
            Self::SevenZip => "application/x-7z-compressed",
            Self::Rar => "application/vnd.rar",
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
            Self::Gif => "image/gif",
            Self::Webp => "image/webp",
            Self::Bmp => "image/bmp",
            Self::Tiff => "image/tiff",
            Self::Heif => "image/heif",
            Self::Avif => "image/avif",
            Self::Wav => "audio/wav",
            Self::Aiff => "audio/aiff",
            Self::Caf => "audio/x-caf",
            Self::Flac => "audio/flac",
            Self::Mp3 => "audio/mpeg",
            Self::Ogg => "application/ogg",
            Self::OggAudio => "audio/ogg",
            Self::OggVideo => "video/ogg",
            Self::M4a => "audio/mp4",
            Self::Mp4 => "video/mp4",
            Self::QuickTime => "video/quicktime",
            Self::Matroska => "video/x-matroska",
            Self::Webm => "video/webm",
            Self::Avi => "video/x-msvideo",
            Self::Executable => "application/x-executable",
            Self::UnknownBinary => "application/octet-stream",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash, Ord, PartialOrd)]
#[serde(rename_all = "snake_case")]
pub enum MediaFamily {
    Image,
    Audio,
    Video,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ObjectStatus {
    Complete,
    Partial { reasons: Vec<String> },
    Opaque,
    Unsupported { code: String },
    Blocked { code: String },
    Malformed { code: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Coverage {
    Complete,
    Partial { reasons: Vec<String> },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AttachmentIssue {
    pub code: String,
    pub class: IssueClass,
    pub severity: IssueSeverity,
    pub object_id: Option<ObjectId>,
    pub edge_index: Option<u32>,
    pub safe_message: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IssueClass {
    Policy,
    Budget,
    Detection,
    Malformed,
    Encrypted,
    Unsupported,
    Integrity,
    Internal,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IssueSeverity {
    Info,
    Warning,
    Blocked,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanonicalArtifact {
    pub schema: String,
    pub id: ArtifactId,
    pub source: ObjectId,
    pub processor: ProcessorProvenance,
    pub trust: ContentTrust,
    pub payload: ArtifactPayload,
    pub warnings: Vec<String>,
}

impl CanonicalArtifact {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.schema != ARTIFACT_SCHEMA {
            return Err(ContractError::SchemaMismatch {
                expected: ARTIFACT_SCHEMA.to_string(),
                actual: self.schema.clone(),
            });
        }
        if self.processor.name.trim().is_empty()
            || self.processor.version.trim().is_empty()
            || self.processor.policy_fingerprint.trim().is_empty()
        {
            return Err(ContractError::InvalidArtifactBlob {
                artifact_id: self.id.0.clone(),
                reason: "processor provenance must not be empty".to_string(),
            });
        }
        match &self.payload {
            ArtifactPayload::Text { text, segments, .. } => {
                let mut previous_end = 0;
                for segment in segments {
                    if segment.start_byte > segment.end_byte
                        || segment.end_byte > text.len()
                        || !text.is_char_boundary(segment.start_byte)
                        || !text.is_char_boundary(segment.end_byte)
                        || segment.start_byte < previous_end
                    {
                        return Err(ContractError::InvalidTextSegment {
                            start: segment.start_byte,
                            end: segment.end_byte,
                            text_len: text.len(),
                        });
                    }
                    previous_end = segment.end_byte;
                }
            }
            ArtifactPayload::Media {
                family,
                blob,
                validation,
                ..
            } => {
                if blob.object_id != self.source
                    || blob.sha256 != self.source.0
                    || blob.sha256 != blob.object_id.0
                {
                    return Err(ContractError::ArtifactBlobSourceMismatch {
                        artifact_id: self.id.0.clone(),
                        artifact_source: self.source.to_string(),
                        blob_object_id: blob.object_id.to_string(),
                        blob_sha256: blob.sha256.clone(),
                    });
                }
                if blob.media_type.trim().is_empty() {
                    return Err(ContractError::InvalidArtifactBlob {
                        artifact_id: self.id.0.clone(),
                        reason: "media_type must not be empty".to_string(),
                    });
                }
                if let Some(media_type_family) = media_family_from_type(&blob.media_type)
                    && media_type_family != *family
                {
                    return Err(ContractError::InvalidArtifactBlob {
                        artifact_id: self.id.0.clone(),
                        reason: format!(
                            "declared media family {family:?} contradicts media type {}",
                            blob.media_type
                        ),
                    });
                }
                validation.validate(self)?;
            }
            ArtifactPayload::Opaque { blob } => {
                if blob.object_id != self.source
                    || blob.sha256 != self.source.0
                    || blob.sha256 != blob.object_id.0
                {
                    return Err(ContractError::ArtifactBlobSourceMismatch {
                        artifact_id: self.id.0.clone(),
                        artifact_source: self.source.to_string(),
                        blob_object_id: blob.object_id.to_string(),
                        blob_sha256: blob.sha256.clone(),
                    });
                }
                if blob.media_type.trim().is_empty() {
                    return Err(ContractError::InvalidArtifactBlob {
                        artifact_id: self.id.0.clone(),
                        reason: "media_type must not be empty".to_string(),
                    });
                }
            }
        }
        Ok(())
    }
}

fn media_family_from_type(media_type: &str) -> Option<MediaFamily> {
    let essence = media_type.split(';').next()?.trim();
    if essence
        .get(.."image/".len())
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("image/"))
    {
        Some(MediaFamily::Image)
    } else if essence
        .get(.."audio/".len())
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("audio/"))
    {
        Some(MediaFamily::Audio)
    } else if essence
        .get(.."video/".len())
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("video/"))
    {
        Some(MediaFamily::Video)
    } else {
        None
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProcessorProvenance {
    pub name: String,
    pub version: String,
    pub policy_fingerprint: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ContentTrust {
    UntrustedAttachmentData,
}

/// Evidence established about the complete retained media blob.
///
/// A signature or metadata probe is useful for classification, but it is not
/// evidence that a decoder consumed the entire payload. Callers must not infer
/// stronger validation than the grade records.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BlobValidationGrade {
    /// Only a header, marker, or bounded structural subset was inspected.
    HeaderOrStructureOnly,
    /// A bounded parser checked the complete container, but did not decode the
    /// media payload.
    WholeFileStructure,
    /// A bounded media decoder consumed the complete payload successfully.
    PayloadDecoded,
}

impl BlobValidationGrade {
    /// Only complete payload decoding is sufficient for direct model media.
    /// Container-only grades remain useful inputs to explicit transforms.
    #[must_use]
    pub const fn permits_direct_media(self) -> bool {
        matches!(self, Self::PayloadDecoded)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BlobValidation {
    pub grade: BlobValidationGrade,
    /// Stable, human-auditable description of the validation operation.
    pub method: String,
    pub validator: ProcessorProvenance,
}

impl BlobValidation {
    fn validate(&self, artifact: &CanonicalArtifact) -> Result<(), ContractError> {
        if self.method.trim().is_empty()
            || self.validator.name.trim().is_empty()
            || self.validator.version.trim().is_empty()
            || self.validator.policy_fingerprint.trim().is_empty()
        {
            return Err(ContractError::InvalidArtifactBlob {
                artifact_id: artifact.id.0.clone(),
                reason: "media validation method and provenance must not be empty".to_string(),
            });
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ArtifactPayload {
    Text {
        format: TextFormat,
        text: String,
        segments: Vec<TextSegment>,
    },
    Media {
        family: MediaFamily,
        blob: BlobRef,
        metadata: MediaMetadata,
        validation: BlobValidation,
    },
    Opaque {
        blob: BlobRef,
    },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TextFormat {
    Plain,
    Markdown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextSegment {
    pub kind: SegmentKind,
    pub label: Option<String>,
    pub start_byte: usize,
    pub end_byte: usize,
    pub coordinates: Option<BTreeMap<String, String>>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SegmentKind {
    Document,
    Page,
    Slide,
    Sheet,
    Row,
    Cell,
    EmailHeader,
    EmailBody,
    NotebookCell,
    ArchiveMember,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BlobRef {
    pub object_id: ObjectId,
    pub sha256: String,
    pub byte_len: u64,
    pub media_type: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct MediaMetadata {
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
    pub channels: Option<u16>,
    pub sample_rate_hz: Option<u32>,
    pub frame_count: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct AttachmentBundle {
    pub graph: AttachmentGraph,
    pub artifacts: Vec<CanonicalArtifact>,
    pub blobs: BTreeMap<ObjectId, Arc<[u8]>>,
}

impl AttachmentBundle {
    pub fn validate(&self) -> Result<(), ContractError> {
        self.graph.validate()?;
        let objects = self
            .graph
            .objects
            .iter()
            .map(|object| &object.id)
            .collect::<BTreeSet<_>>();
        let mut artifacts = BTreeSet::new();
        let mut artifacts_by_source = BTreeMap::<&ObjectId, BTreeSet<&ArtifactId>>::new();
        let mut text_bytes = 0_u64;
        let mut media_objects = 0_u32;
        let mut media_bytes = 0_u64;
        for artifact in &self.artifacts {
            artifact.validate()?;
            if !objects.contains(&artifact.source) {
                return Err(ContractError::MissingObject(artifact.source.to_string()));
            }
            if !artifacts.insert(&artifact.id) {
                return Err(ContractError::DuplicateArtifact(artifact.id.0.clone()));
            }
            artifacts_by_source
                .entry(&artifact.source)
                .or_default()
                .insert(&artifact.id);
            match &artifact.payload {
                ArtifactPayload::Text { text, .. } => {
                    let bytes =
                        u64::try_from(text.len()).map_err(|_| ContractError::IntegerOverflow)?;
                    text_bytes = text_bytes
                        .checked_add(bytes)
                        .ok_or(ContractError::IntegerOverflow)?;
                }
                ArtifactPayload::Media { blob, .. } => {
                    media_objects = media_objects
                        .checked_add(1)
                        .ok_or(ContractError::IntegerOverflow)?;
                    media_bytes = media_bytes
                        .checked_add(blob.byte_len)
                        .ok_or(ContractError::IntegerOverflow)?;
                }
                ArtifactPayload::Opaque { .. } => {}
            }
        }
        if self.graph.usage.text_bytes != text_bytes
            || self.graph.usage.media_objects != media_objects
            || self.graph.usage.media_bytes != media_bytes
        {
            return Err(ContractError::InvalidGraph(format!(
                "canonical usage ({}, {}, {} text bytes/media objects/media bytes) does not match retained artifacts ({text_bytes}, {media_objects}, {media_bytes})",
                self.graph.usage.text_bytes,
                self.graph.usage.media_objects,
                self.graph.usage.media_bytes
            )));
        }
        for object in &self.graph.objects {
            let declared = object.artifact_ids.iter().collect::<BTreeSet<_>>();
            if declared.len() != object.artifact_ids.len() {
                return Err(ContractError::DuplicateObjectArtifactReference(
                    object.id.to_string(),
                ));
            }
            let actual = artifacts_by_source.remove(&object.id).unwrap_or_default();
            if declared != actual {
                return Err(ContractError::ObjectArtifactReferenceMismatch(
                    object.id.to_string(),
                ));
            }
            if !self.blobs.contains_key(&object.id) {
                return Err(ContractError::MissingBlob(object.id.to_string()));
            }
        }
        let retained_bytes = self.blobs.values().try_fold(0_u64, |total, bytes| {
            let bytes = u64::try_from(bytes.len()).map_err(|_| ContractError::IntegerOverflow)?;
            total
                .checked_add(bytes)
                .ok_or(ContractError::IntegerOverflow)
        })?;
        if retained_bytes != self.graph.usage.retained_bytes {
            return Err(ContractError::InvalidGraph(format!(
                "retained-byte usage {} does not match retained blobs {retained_bytes}",
                self.graph.usage.retained_bytes
            )));
        }
        for (object_id, bytes) in &self.blobs {
            if !objects.contains(object_id) {
                return Err(ContractError::MissingObject(object_id.to_string()));
            }
            let expected = self
                .graph
                .objects
                .iter()
                .find(|object| &object.id == object_id)
                .map(|object| object.byte_len)
                .ok_or_else(|| ContractError::MissingObject(object_id.to_string()))?;
            let actual = u64::try_from(bytes.len()).map_err(|_| ContractError::IntegerOverflow)?;
            if expected != actual {
                return Err(ContractError::BlobLengthMismatch {
                    object_id: object_id.to_string(),
                    expected,
                    actual,
                });
            }
            let actual_sha256 = format!("{:x}", Sha256::digest(bytes));
            if object_id.0 != actual_sha256 {
                return Err(ContractError::BlobHashMismatch {
                    object_id: object_id.to_string(),
                    actual: actual_sha256,
                });
            }
        }
        for artifact in &self.artifacts {
            let blob = match &artifact.payload {
                ArtifactPayload::Media { blob, .. } | ArtifactPayload::Opaque { blob } => blob,
                ArtifactPayload::Text { .. } => continue,
            };
            let source = self
                .graph
                .objects
                .iter()
                .find(|object| object.id == artifact.source)
                .ok_or_else(|| ContractError::MissingObject(artifact.source.to_string()))?;
            if blob.byte_len != source.byte_len {
                return Err(ContractError::InvalidArtifactBlob {
                    artifact_id: artifact.id.0.clone(),
                    reason: format!(
                        "declared blob length {} does not match source length {}",
                        blob.byte_len, source.byte_len
                    ),
                });
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TargetCapabilities {
    pub target_id: String,
    pub fingerprint: String,
    pub accepted_media_types: BTreeSet<String>,
    pub accepted_media_families: BTreeSet<MediaFamily>,
    pub max_media_objects: u32,
    pub max_media_bytes: u64,
    pub max_text_bytes: u64,
    pub supports_markdown: bool,
    pub supports_native_pdf: bool,
    pub supports_native_video: bool,
}

impl TargetCapabilities {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.target_id.trim().is_empty() || self.fingerprint.trim().is_empty() {
            return Err(ContractError::InvalidCapabilities(
                "target_id and fingerprint must not be empty".to_string(),
            ));
        }
        if self.max_media_objects == 0 || self.max_media_bytes == 0 || self.max_text_bytes == 0 {
            return Err(ContractError::InvalidCapabilities(
                "target media and text limits must be greater than zero".to_string(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct PreparationPolicy {
    #[serde(default)]
    pub image: ImagePreparationPolicy,
    #[serde(default)]
    pub audio: AudioPreparationPolicy,
    #[serde(default)]
    pub video: VideoPreparationPolicy,
    #[serde(default)]
    pub document: DocumentPreparationPolicy,
    #[serde(default)]
    pub unsupported: UnsupportedPreparationPolicy,
}

impl Default for PreparationPolicy {
    fn default() -> Self {
        Self {
            image: ImagePreparationPolicy::DirectWhenSupported,
            audio: AudioPreparationPolicy::DirectThenTranscribe,
            video: VideoPreparationPolicy::DirectThenFramesAndTranscript,
            document: DocumentPreparationPolicy::CanonicalTextThenNative,
            unsupported: UnsupportedPreparationPolicy::Block,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ImagePreparationPolicy {
    #[default]
    DirectWhenSupported,
    OcrOnly,
    DirectAndOcr,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AudioPreparationPolicy {
    #[default]
    DirectThenTranscribe,
    TranscribeOnly,
    DirectAndTranscribe,
    DirectOnly,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum VideoPreparationPolicy {
    #[default]
    DirectThenFramesAndTranscript,
    FramesAndTranscript,
    FramesOnly,
    TranscriptOnly,
    DirectOnly,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DocumentPreparationPolicy {
    NativeThenCanonicalText,
    #[default]
    CanonicalTextThenNative,
    CanonicalTextOnly,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UnsupportedPreparationPolicy {
    #[default]
    Block,
    PreserveAsOpaqueReference,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PreparationPlan {
    pub schema: String,
    pub plan_id: String,
    pub target_id: String,
    pub target_fingerprint: String,
    pub source_job_id: AttachmentJobId,
    pub parts: Vec<PreparedPart>,
    pub transforms: Vec<TransformRequest>,
    pub blockers: Vec<PreparationBlocker>,
    pub warnings: Vec<String>,
    /// Shared output budget for the entire plan. Individual transform limits
    /// are additional per-call caps; they do not grant each transform a fresh
    /// copy of these totals.
    pub aggregate_limits: PreparationAggregateLimits,
    pub cache_fingerprint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PreparationAggregateLimits {
    pub max_text_bytes: u64,
    pub max_media_objects: u32,
    pub max_media_bytes: u64,
    pub max_transform_requests: u32,
}

impl PreparationAggregateLimits {
    fn validate(&self) -> Result<(), ContractError> {
        if self.max_text_bytes == 0
            || self.max_media_objects == 0
            || self.max_media_bytes == 0
            || self.max_transform_requests == 0
        {
            return Err(ContractError::InvalidPreparationPlan(
                "aggregate preparation limits must all be greater than zero".to_string(),
            ));
        }
        Ok(())
    }
}

impl PreparationPlan {
    pub fn validate(&self) -> Result<(), ContractError> {
        if self.schema != PLAN_SCHEMA {
            return Err(ContractError::SchemaMismatch {
                expected: PLAN_SCHEMA.to_string(),
                actual: self.schema.clone(),
            });
        }
        if self.target_id.trim().is_empty()
            || self.target_fingerprint.trim().is_empty()
            || self.source_job_id.0.trim().is_empty()
            || self.cache_fingerprint.len() != 64
            || !self
                .cache_fingerprint
                .bytes()
                .all(|value| value.is_ascii_hexdigit() && !value.is_ascii_uppercase())
            || self.plan_id != format!("plan-{}", self.cache_fingerprint)
        {
            return Err(ContractError::InvalidPreparationPlan(
                "plan, target, source-job, and cache identifiers are invalid".to_string(),
            ));
        }
        self.aggregate_limits.validate()?;

        let mut prepared_artifacts = BTreeSet::new();
        let mut direct_text_bytes = 0_u64;
        let mut direct_media_objects = 0_u32;
        let mut direct_media_bytes = 0_u64;
        for part in &self.parts {
            let artifact_id = match part {
                PreparedPart::UntrustedText {
                    artifact_id,
                    text,
                    source,
                    ..
                } => {
                    if source.0.trim().is_empty() {
                        return Err(ContractError::InvalidPreparationPlan(
                            "prepared text has an empty source object".to_string(),
                        ));
                    }
                    direct_text_bytes = direct_text_bytes
                        .checked_add(
                            u64::try_from(text.len())
                                .map_err(|_| ContractError::IntegerOverflow)?,
                        )
                        .ok_or(ContractError::IntegerOverflow)?;
                    artifact_id
                }
                PreparedPart::DirectMedia {
                    artifact_id,
                    blob,
                    source,
                    ..
                }
                | PreparedPart::OpaqueReference {
                    artifact_id,
                    blob,
                    source,
                } => {
                    validate_prepared_blob(artifact_id, source, blob)?;
                    direct_media_objects = direct_media_objects
                        .checked_add(1)
                        .ok_or(ContractError::IntegerOverflow)?;
                    direct_media_bytes = direct_media_bytes
                        .checked_add(blob.byte_len)
                        .ok_or(ContractError::IntegerOverflow)?;
                    artifact_id
                }
            };
            if artifact_id.0.trim().is_empty() {
                return Err(ContractError::InvalidPreparationPlan(
                    "prepared artifact identifiers must not be empty".to_string(),
                ));
            }
            if !prepared_artifacts.insert(artifact_id) {
                return Err(ContractError::DuplicatePreparedArtifact(
                    artifact_id.0.clone(),
                ));
            }
        }
        if direct_text_bytes > self.aggregate_limits.max_text_bytes
            || direct_media_objects > self.aggregate_limits.max_media_objects
            || direct_media_bytes > self.aggregate_limits.max_media_bytes
        {
            return Err(ContractError::InvalidPreparationPlan(
                "prepared parts exceed the plan's shared aggregate output budget".to_string(),
            ));
        }

        let mut transform_ids = BTreeSet::new();
        let transform_count =
            u32::try_from(self.transforms.len()).map_err(|_| ContractError::IntegerOverflow)?;
        if transform_count > self.aggregate_limits.max_transform_requests {
            return Err(ContractError::InvalidPreparationPlan(
                "transform requests exceed the plan's shared aggregate request budget".to_string(),
            ));
        }
        for transform in &self.transforms {
            if transform.id.trim().is_empty()
                || transform.source_artifact.0.trim().is_empty()
                || transform.source.0.trim().is_empty()
            {
                return Err(ContractError::InvalidPreparationPlan(
                    "transform request, artifact, and source identifiers must not be empty"
                        .to_string(),
                ));
            }
            if !transform_ids.insert(&transform.id) {
                return Err(ContractError::DuplicateTransformRequest(
                    transform.id.clone(),
                ));
            }
            let mut dependencies = BTreeSet::new();
            for dependency in &transform.depends_on {
                if dependency.trim().is_empty() {
                    return Err(ContractError::InvalidPreparationPlan(format!(
                        "transform request {} has an empty dependency identifier",
                        transform.id
                    )));
                }
                if !dependencies.insert(dependency) {
                    return Err(ContractError::InvalidPreparationPlan(format!(
                        "transform request {} repeats dependency {}",
                        transform.id, dependency
                    )));
                }
                if dependency == &transform.id {
                    return Err(ContractError::InvalidPreparationPlan(format!(
                        "transform request {} cannot depend on itself",
                        transform.id
                    )));
                }
                if !transform_ids.contains(dependency) {
                    return Err(ContractError::InvalidPreparationPlan(format!(
                        "transform request {} depends on missing or later transform {}",
                        transform.id, dependency
                    )));
                }
            }
            if transform.limits.max_input_bytes == 0
                || transform.limits.max_output_bytes == 0
                || transform.limits.timeout_ms == 0
            {
                return Err(ContractError::InvalidPreparationPlan(format!(
                    "transform request {} has an unbounded or zero limit",
                    transform.id
                )));
            }
            let aggregate_output_limit = match transform.operation {
                TransformOperation::OcrImage
                | TransformOperation::TranscribeAudio
                | TransformOperation::ExtractDocumentText => self.aggregate_limits.max_text_bytes,
                TransformOperation::ExtractVideoAudio
                | TransformOperation::SampleVideoFrames { .. }
                | TransformOperation::RasterizePdfPages { .. } => {
                    self.aggregate_limits.max_media_bytes
                }
            };
            if transform.limits.max_output_bytes > aggregate_output_limit {
                return Err(ContractError::InvalidPreparationPlan(format!(
                    "transform request {} exceeds the plan's shared aggregate output budget",
                    transform.id
                )));
            }
            match transform.operation {
                TransformOperation::SampleVideoFrames { max_frames }
                    if max_frames == 0 || max_frames > self.aggregate_limits.max_media_objects =>
                {
                    return Err(ContractError::InvalidPreparationPlan(format!(
                        "transform request {} has an invalid frame limit",
                        transform.id
                    )));
                }
                TransformOperation::RasterizePdfPages { max_pages, .. }
                    if max_pages == 0 || max_pages > self.aggregate_limits.max_media_objects =>
                {
                    return Err(ContractError::InvalidPreparationPlan(format!(
                        "transform request {} has an invalid page limit",
                        transform.id
                    )));
                }
                _ => {}
            }
        }
        for blocker in &self.blockers {
            if blocker.code.trim().is_empty() || blocker.safe_message.trim().is_empty() {
                return Err(ContractError::InvalidPreparationPlan(
                    "preparation blocker codes and safe messages must not be empty".to_string(),
                ));
            }
        }
        Ok(())
    }

    /// Validates every executable plan reference against the immutable bundle
    /// that supplied it. This is the required validation boundary after a plan
    /// has been serialized, cached, or otherwise separated from its bundle.
    pub fn validate_against(&self, bundle: &AttachmentBundle) -> Result<(), ContractError> {
        self.validate()?;
        bundle.validate()?;
        if self.source_job_id != bundle.graph.job_id {
            return Err(ContractError::InvalidPreparationPlan(
                "the preparation plan belongs to a different inspection job".to_string(),
            ));
        }
        let artifacts = bundle
            .artifacts
            .iter()
            .map(|artifact| (&artifact.id, artifact))
            .collect::<BTreeMap<_, _>>();
        let objects = bundle
            .graph
            .objects
            .iter()
            .map(|object| &object.id)
            .collect::<BTreeSet<_>>();

        for part in &self.parts {
            let artifact_id = match part {
                PreparedPart::UntrustedText {
                    artifact_id,
                    format,
                    text,
                    source,
                } => {
                    let artifact = artifacts.get(artifact_id).ok_or_else(|| {
                        ContractError::InvalidPreparationPlan(format!(
                            "prepared part references missing artifact {}",
                            artifact_id.0
                        ))
                    })?;
                    let ArtifactPayload::Text {
                        format: artifact_format,
                        text: artifact_text,
                        ..
                    } = &artifact.payload
                    else {
                        return Err(ContractError::InvalidPreparationPlan(format!(
                            "prepared text {} does not reference a text artifact",
                            artifact_id.0
                        )));
                    };
                    let format_matches = format == artifact_format
                        || (*format == TextFormat::Plain
                            && *artifact_format == TextFormat::Markdown);
                    if source != &artifact.source || text != artifact_text || !format_matches {
                        return Err(ContractError::InvalidPreparationPlan(format!(
                            "prepared text {} does not match its canonical artifact",
                            artifact_id.0
                        )));
                    }
                    artifact_id
                }
                PreparedPart::DirectMedia {
                    artifact_id,
                    family,
                    blob,
                    source,
                } => {
                    let artifact = artifacts.get(artifact_id).ok_or_else(|| {
                        ContractError::InvalidPreparationPlan(format!(
                            "prepared part references missing artifact {}",
                            artifact_id.0
                        ))
                    })?;
                    if !matches!(
                        &artifact.payload,
                        ArtifactPayload::Media {
                            family: artifact_family,
                            blob: artifact_blob,
                            ..
                        } if artifact_family == family
                            && artifact_blob == blob
                            && &artifact.source == source
                    ) {
                        return Err(ContractError::InvalidPreparationPlan(format!(
                            "direct media {} does not match its canonical artifact",
                            artifact_id.0
                        )));
                    }
                    artifact_id
                }
                PreparedPart::OpaqueReference {
                    artifact_id,
                    blob,
                    source,
                } => {
                    let artifact = artifacts.get(artifact_id).ok_or_else(|| {
                        ContractError::InvalidPreparationPlan(format!(
                            "prepared part references missing artifact {}",
                            artifact_id.0
                        ))
                    })?;
                    if !matches!(
                        &artifact.payload,
                        ArtifactPayload::Opaque { blob: artifact_blob }
                            if artifact_blob == blob && &artifact.source == source
                    ) {
                        return Err(ContractError::InvalidPreparationPlan(format!(
                            "opaque reference {} does not match its canonical artifact",
                            artifact_id.0
                        )));
                    }
                    artifact_id
                }
            };
            if !artifacts.contains_key(artifact_id) {
                return Err(ContractError::InvalidPreparationPlan(format!(
                    "prepared part references missing artifact {}",
                    artifact_id.0
                )));
            }
        }

        for transform in &self.transforms {
            let artifact = artifacts.get(&transform.source_artifact).ok_or_else(|| {
                ContractError::InvalidPreparationPlan(format!(
                    "transform {} references missing artifact {}",
                    transform.id, transform.source_artifact.0
                ))
            })?;
            let expected_input_bytes = match &artifact.payload {
                ArtifactPayload::Text { text, .. } => {
                    u64::try_from(text.len()).map_err(|_| ContractError::IntegerOverflow)?
                }
                ArtifactPayload::Media { blob, .. } | ArtifactPayload::Opaque { blob } => {
                    blob.byte_len
                }
            };
            if transform.source != artifact.source
                || transform.limits.max_input_bytes != expected_input_bytes
            {
                return Err(ContractError::InvalidPreparationPlan(format!(
                    "transform {} does not match its canonical source artifact",
                    transform.id
                )));
            }
        }

        for blocker in &self.blockers {
            let artifact = blocker
                .artifact_id
                .as_ref()
                .map(|artifact_id| {
                    artifacts.get(artifact_id).copied().ok_or_else(|| {
                        ContractError::InvalidPreparationPlan(format!(
                            "blocker references missing artifact {}",
                            artifact_id.0
                        ))
                    })
                })
                .transpose()?;
            if let Some(source) = &blocker.source
                && !objects.contains(source)
            {
                return Err(ContractError::InvalidPreparationPlan(format!(
                    "blocker references missing source object {source}"
                )));
            }
            if let (Some(artifact), Some(source)) = (artifact, &blocker.source)
                && &artifact.source != source
            {
                return Err(ContractError::InvalidPreparationPlan(
                    "blocker artifact and source references disagree".to_string(),
                ));
            }
        }
        Ok(())
    }
}

fn validate_prepared_blob(
    artifact_id: &ArtifactId,
    source: &ObjectId,
    blob: &BlobRef,
) -> Result<(), ContractError> {
    if blob.object_id != *source
        || blob.sha256 != source.0
        || blob.sha256 != blob.object_id.0
        || blob.media_type.trim().is_empty()
    {
        return Err(ContractError::InvalidPreparationPlan(format!(
            "prepared artifact {} has an invalid blob reference",
            artifact_id.0
        )));
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PreparedPart {
    UntrustedText {
        artifact_id: ArtifactId,
        format: TextFormat,
        text: String,
        source: ObjectId,
    },
    DirectMedia {
        artifact_id: ArtifactId,
        family: MediaFamily,
        blob: BlobRef,
        source: ObjectId,
    },
    OpaqueReference {
        artifact_id: ArtifactId,
        blob: BlobRef,
        source: ObjectId,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TransformRequest {
    pub id: String,
    /// Ordered predecessor transforms whose bounded outputs become this
    /// transform's inputs. Dependencies must refer to earlier requests in the
    /// plan, making the serialized vector a validated topological order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub depends_on: Vec<String>,
    pub source_artifact: ArtifactId,
    pub source: ObjectId,
    pub operation: TransformOperation,
    pub required: bool,
    pub limits: TransformLimits,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TransformOperation {
    TranscribeAudio,
    ExtractVideoAudio,
    SampleVideoFrames { max_frames: u32 },
    OcrImage,
    RasterizePdfPages { max_pages: u32, max_megapixels: u32 },
    ExtractDocumentText,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TransformLimits {
    pub max_input_bytes: u64,
    pub max_output_bytes: u64,
    pub timeout_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PreparationBlocker {
    pub code: String,
    pub safe_message: String,
    pub artifact_id: Option<ArtifactId>,
    pub source: Option<ObjectId>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AttachmentReceipt {
    pub schema: String,
    pub job_id: AttachmentJobId,
    pub status: ReceiptStatus,
    pub root_sha256: String,
    pub policy_fingerprint: String,
    pub processor_versions: BTreeMap<String, String>,
    pub usage: BudgetUsage,
    pub complete_coverage: bool,
    pub network_used: bool,
    pub process_used: bool,
    pub model_invoked: bool,
    pub changed_paths: Vec<String>,
}

impl AttachmentReceipt {
    pub fn validate_against(
        &self,
        bundle: &AttachmentBundle,
        plan: Option<&PreparationPlan>,
    ) -> Result<(), ContractError> {
        if self.schema != RECEIPT_SCHEMA {
            return Err(ContractError::SchemaMismatch {
                expected: RECEIPT_SCHEMA.to_string(),
                actual: self.schema.clone(),
            });
        }
        bundle.validate()?;
        let graph = &bundle.graph;
        if self.job_id != graph.job_id
            || self.root_sha256 != graph.root.0
            || self.usage != graph.usage
        {
            return Err(ContractError::InvalidReceipt(
                "receipt identity or usage does not match its graph".to_string(),
            ));
        }
        let partial = !matches!(graph.coverage, Coverage::Complete);
        if self.complete_coverage == partial {
            return Err(ContractError::InvalidReceipt(
                "receipt coverage does not match its graph".to_string(),
            ));
        }
        if self.policy_fingerprint.trim().is_empty()
            || self.processor_versions.is_empty()
            || self
                .processor_versions
                .iter()
                .any(|(name, version)| name.trim().is_empty() || version.trim().is_empty())
        {
            return Err(ContractError::InvalidReceipt(
                "receipt policy and processor provenance must not be empty".to_string(),
            ));
        }
        let blocked = if let Some(plan) = plan {
            plan.validate_against(bundle)?;
            !plan.blockers.is_empty()
        } else {
            false
        };
        let fully_blocked =
            blocked && plan.is_some_and(|plan| plan.parts.is_empty() && plan.transforms.is_empty());
        let expected_status = if fully_blocked {
            ReceiptStatus::Blocked
        } else if blocked || partial {
            ReceiptStatus::Partial
        } else {
            ReceiptStatus::Passed
        };
        if self.status != expected_status {
            return Err(ContractError::InvalidReceipt(format!(
                "receipt status {:?} does not match derived status {expected_status:?}",
                self.status
            )));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReceiptStatus {
    Passed,
    Partial,
    Blocked,
    Failed,
}

#[derive(Debug, Error, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[error("{code}: {safe_message}")]
pub struct AttachmentError {
    pub code: String,
    pub class: IssueClass,
    pub safe_message: String,
    pub object_id: Option<ObjectId>,
    pub retryable: bool,
}

impl AttachmentError {
    #[must_use]
    pub fn blocked(code: impl Into<String>, safe_message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            class: IssueClass::Policy,
            safe_message: safe_message.into(),
            object_id: None,
            retryable: false,
        }
    }

    #[must_use]
    pub fn budget(code: impl Into<String>, safe_message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            class: IssueClass::Budget,
            safe_message: safe_message.into(),
            object_id: None,
            retryable: false,
        }
    }
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ContractError {
    #[error("schema mismatch: expected {expected}, got {actual}")]
    SchemaMismatch { expected: String, actual: String },
    #[error("invalid budget: {0}")]
    InvalidBudget(String),
    #[error("invalid target capabilities: {0}")]
    InvalidCapabilities(String),
    #[error("missing object {0}")]
    MissingObject(String),
    #[error("missing retained blob for object {0}")]
    MissingBlob(String),
    #[error("invalid attachment graph: {0}")]
    InvalidGraph(String),
    #[error("duplicate object {0}")]
    DuplicateObject(String),
    #[error("duplicate artifact {0}")]
    DuplicateArtifact(String),
    #[error("object {0} contains duplicate artifact references")]
    DuplicateObjectArtifactReference(String),
    #[error("object {0} artifact references do not match emitted artifacts")]
    ObjectArtifactReferenceMismatch(String),
    #[error("duplicate prepared artifact {0}")]
    DuplicatePreparedArtifact(String),
    #[error("duplicate transform request {0}")]
    DuplicateTransformRequest(String),
    #[error("invalid preparation plan: {0}")]
    InvalidPreparationPlan(String),
    #[error("invalid sha256 {0}")]
    InvalidHash(String),
    #[error("object id does not match sha256 for {0}")]
    ObjectIdHashMismatch(String),
    #[error("depth {0} is outside graph limits")]
    DepthOutOfRange(u16),
    #[error("invalid UTF-8 text segment {start}..{end} for text length {text_len}")]
    InvalidTextSegment {
        start: usize,
        end: usize,
        text_len: usize,
    },
    #[error("blob {object_id} length mismatch: expected {expected}, got {actual}")]
    BlobLengthMismatch {
        object_id: String,
        expected: u64,
        actual: u64,
    },
    #[error("blob {object_id} content hash mismatch: got {actual}")]
    BlobHashMismatch { object_id: String, actual: String },
    #[error(
        "artifact {artifact_id} source {artifact_source} does not match blob object {blob_object_id} / hash {blob_sha256}"
    )]
    ArtifactBlobSourceMismatch {
        artifact_id: String,
        artifact_source: String,
        blob_object_id: String,
        blob_sha256: String,
    },
    #[error("artifact {artifact_id} contains an invalid blob reference: {reason}")]
    InvalidArtifactBlob { artifact_id: String, reason: String },
    #[error("invalid attachment receipt: {0}")]
    InvalidReceipt(String),
    #[error("integer conversion overflow")]
    IntegerOverflow,
}

const fn default_true() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_inspection_policy_is_valid_by_construction() {
        assert!(InspectionPolicy::default().validate().is_ok());
    }

    #[test]
    fn budget_usage_dominance_checks_every_counter() {
        let earlier = BudgetUsage {
            root_bytes: 1,
            total_derived_bytes: 2,
            retained_bytes: 3,
            objects: 4,
            edges: 5,
            entries: 6,
            deepest_object: 7,
            text_bytes: 8,
            media_objects: 9,
            media_bytes: 10,
            transform_requests: 11,
        };
        let later = BudgetUsage {
            root_bytes: 2,
            total_derived_bytes: 3,
            retained_bytes: 4,
            objects: 5,
            edges: 6,
            entries: 7,
            deepest_object: 8,
            text_bytes: 9,
            media_objects: 10,
            media_bytes: 11,
            transform_requests: 12,
        };
        assert!(later.dominates(&earlier));
        for field in 0..11 {
            let mut regressed = later.clone();
            match field {
                0 => regressed.root_bytes = 0,
                1 => regressed.total_derived_bytes = 1,
                2 => regressed.retained_bytes = 2,
                3 => regressed.objects = 3,
                4 => regressed.edges = 4,
                5 => regressed.entries = 5,
                6 => regressed.deepest_object = 6,
                7 => regressed.text_bytes = 7,
                8 => regressed.media_objects = 8,
                9 => regressed.media_bytes = 9,
                10 => regressed.transform_requests = 10,
                _ => unreachable!(),
            }
            assert!(!regressed.dominates(&earlier), "field {field}");
        }
    }

    fn complete_root_graph() -> AttachmentGraph {
        let root = ObjectId("a".repeat(64));
        AttachmentGraph {
            schema: GRAPH_SCHEMA.to_string(),
            job_id: AttachmentJobId::new(),
            root: root.clone(),
            root_name: LogicalName::provided("fixture.bin"),
            objects: vec![ObjectRecord {
                id: root,
                sha256: "a".repeat(64),
                byte_len: 4,
                detection: Detection {
                    selected: None,
                    candidates: Vec::new(),
                    extension_hint: None,
                    declared_media_type: None,
                    mismatch: None,
                },
                status: ObjectStatus::Complete,
                first_depth: 0,
                artifact_ids: Vec::new(),
            }],
            edges: Vec::new(),
            issues: Vec::new(),
            coverage: Coverage::Complete,
            limits: BudgetLimits::default(),
            usage: BudgetUsage {
                root_bytes: 4,
                objects: 1,
                ..BudgetUsage::default()
            },
        }
    }

    fn complete_derived_graph() -> AttachmentGraph {
        let mut graph = complete_root_graph();
        let child = ObjectId("b".repeat(64));
        graph.objects.push(ObjectRecord {
            id: child.clone(),
            sha256: child.0.clone(),
            byte_len: 2,
            detection: Detection {
                selected: None,
                candidates: Vec::new(),
                extension_hint: None,
                declared_media_type: None,
                mismatch: None,
            },
            status: ObjectStatus::Complete,
            first_depth: 1,
            artifact_ids: Vec::new(),
        });
        graph.edges.push(DerivationEdge {
            parent: graph.root.clone(),
            child: Some(child),
            depth: 1,
            name: LogicalName::provided("child.bin"),
            transform: TransformProvenance {
                kind: TransformKind::ZipMember,
                implementation: "fixture".to_string(),
                version: "1".to_string(),
            },
            declared_uncompressed_bytes: Some(2),
            compressed_bytes: Some(2),
            source_range: Some(ByteRange {
                start: 0,
                end_exclusive: 2,
            }),
            outcome: EdgeOutcome::Derived,
        });
        graph.usage.total_derived_bytes = 2;
        graph.usage.objects = 2;
        graph.usage.edges = 1;
        graph.usage.entries = 1;
        graph.usage.deepest_object = 1;
        graph
    }

    #[test]
    fn default_budget_is_internally_consistent() {
        assert_eq!(BudgetLimits::default().validate(), Ok(()));
    }

    #[test]
    fn text_segments_are_utf8_byte_ranges() {
        let artifact = CanonicalArtifact {
            schema: ARTIFACT_SCHEMA.to_string(),
            id: ArtifactId::new(),
            source: ObjectId("a".repeat(64)),
            processor: ProcessorProvenance {
                name: "fixture".to_string(),
                version: "1".to_string(),
                policy_fingerprint: "fixture".to_string(),
            },
            trust: ContentTrust::UntrustedAttachmentData,
            payload: ArtifactPayload::Text {
                format: TextFormat::Plain,
                text: "abé".to_string(),
                segments: vec![TextSegment {
                    kind: SegmentKind::Document,
                    label: None,
                    start_byte: 0,
                    end_byte: 3,
                    coordinates: None,
                }],
            },
            warnings: Vec::new(),
        };
        assert!(matches!(
            artifact.validate(),
            Err(ContractError::InvalidTextSegment { .. })
        ));
    }

    #[test]
    fn media_blob_cannot_substitute_a_different_graph_object() {
        let source = ObjectId("a".repeat(64));
        let substituted = ObjectId("b".repeat(64));
        let artifact = CanonicalArtifact {
            schema: ARTIFACT_SCHEMA.to_string(),
            id: ArtifactId::new(),
            source: source.clone(),
            processor: ProcessorProvenance {
                name: "fixture".to_string(),
                version: "1".to_string(),
                policy_fingerprint: "fixture".to_string(),
            },
            trust: ContentTrust::UntrustedAttachmentData,
            payload: ArtifactPayload::Media {
                family: MediaFamily::Image,
                blob: BlobRef {
                    object_id: substituted.clone(),
                    sha256: substituted.0,
                    byte_len: 4,
                    media_type: "image/png".to_string(),
                },
                metadata: MediaMetadata::default(),
                validation: BlobValidation {
                    grade: BlobValidationGrade::PayloadDecoded,
                    method: "fixture decoder".to_string(),
                    validator: ProcessorProvenance {
                        name: "fixture".to_string(),
                        version: "1".to_string(),
                        policy_fingerprint: "fixture".to_string(),
                    },
                },
            },
            warnings: Vec::new(),
        };

        assert!(matches!(
            artifact.validate(),
            Err(ContractError::ArtifactBlobSourceMismatch { .. })
        ));
    }

    #[test]
    fn media_family_must_agree_with_the_declared_media_type() {
        let source = ObjectId("a".repeat(64));
        let artifact = CanonicalArtifact {
            schema: ARTIFACT_SCHEMA.to_string(),
            id: ArtifactId::new(),
            source: source.clone(),
            processor: ProcessorProvenance {
                name: "fixture".to_string(),
                version: "1".to_string(),
                policy_fingerprint: "fixture".to_string(),
            },
            trust: ContentTrust::UntrustedAttachmentData,
            payload: ArtifactPayload::Media {
                family: MediaFamily::Image,
                blob: BlobRef {
                    object_id: source.clone(),
                    sha256: source.0,
                    byte_len: 4,
                    media_type: "audio/wav".to_string(),
                },
                metadata: MediaMetadata::default(),
                validation: BlobValidation {
                    grade: BlobValidationGrade::PayloadDecoded,
                    method: "fixture decoder".to_string(),
                    validator: ProcessorProvenance {
                        name: "fixture".to_string(),
                        version: "1".to_string(),
                        policy_fingerprint: "fixture".to_string(),
                    },
                },
            },
            warnings: Vec::new(),
        };

        assert!(matches!(
            artifact.validate(),
            Err(ContractError::InvalidArtifactBlob { reason, .. })
                if reason.contains("contradicts media type")
        ));
    }

    #[test]
    fn bundle_usage_must_reconcile_with_retained_canonical_artifacts() {
        let bytes = Arc::<[u8]>::from(b"root".as_slice());
        let root_hash = format!("{:x}", Sha256::digest(&bytes));
        let root = ObjectId(root_hash.clone());
        let text_id = ArtifactId::new();
        let media_id = ArtifactId::new();
        let graph = AttachmentGraph {
            schema: GRAPH_SCHEMA.to_string(),
            job_id: AttachmentJobId::new(),
            root: root.clone(),
            root_name: LogicalName::provided("fixture.bin"),
            objects: vec![ObjectRecord {
                id: root.clone(),
                sha256: root_hash,
                byte_len: 4,
                detection: Detection {
                    selected: None,
                    candidates: Vec::new(),
                    extension_hint: None,
                    declared_media_type: None,
                    mismatch: None,
                },
                status: ObjectStatus::Complete,
                first_depth: 0,
                artifact_ids: vec![text_id.clone(), media_id.clone()],
            }],
            edges: Vec::new(),
            issues: Vec::new(),
            coverage: Coverage::Complete,
            limits: BudgetLimits::default(),
            usage: BudgetUsage {
                root_bytes: 4,
                retained_bytes: 4,
                objects: 1,
                text_bytes: 4,
                media_objects: 1,
                media_bytes: 4,
                ..BudgetUsage::default()
            },
        };
        let provenance = ProcessorProvenance {
            name: "fixture".to_string(),
            version: "1".to_string(),
            policy_fingerprint: "fixture".to_string(),
        };
        let mut bundle = AttachmentBundle {
            graph,
            artifacts: vec![
                CanonicalArtifact {
                    schema: ARTIFACT_SCHEMA.to_string(),
                    id: text_id,
                    source: root.clone(),
                    processor: provenance.clone(),
                    trust: ContentTrust::UntrustedAttachmentData,
                    payload: ArtifactPayload::Text {
                        format: TextFormat::Plain,
                        text: "text".to_string(),
                        segments: Vec::new(),
                    },
                    warnings: Vec::new(),
                },
                CanonicalArtifact {
                    schema: ARTIFACT_SCHEMA.to_string(),
                    id: media_id,
                    source: root.clone(),
                    processor: provenance.clone(),
                    trust: ContentTrust::UntrustedAttachmentData,
                    payload: ArtifactPayload::Media {
                        family: MediaFamily::Image,
                        blob: BlobRef {
                            object_id: root.clone(),
                            sha256: root.0.clone(),
                            byte_len: 4,
                            media_type: "image/png".to_string(),
                        },
                        metadata: MediaMetadata::default(),
                        validation: BlobValidation {
                            grade: BlobValidationGrade::PayloadDecoded,
                            method: "fixture decoder".to_string(),
                            validator: provenance,
                        },
                    },
                    warnings: Vec::new(),
                },
            ],
            blobs: BTreeMap::from([(root, bytes)]),
        };
        assert_eq!(bundle.validate(), Ok(()));

        bundle.graph.usage.text_bytes = 0;
        assert!(matches!(
            bundle.validate(),
            Err(ContractError::InvalidGraph(message))
                if message.contains("does not match retained artifacts")
        ));
        bundle.graph.usage.text_bytes = 4;
        bundle.graph.usage.media_objects = 0;
        assert!(matches!(
            bundle.validate(),
            Err(ContractError::InvalidGraph(message))
                if message.contains("does not match retained artifacts")
        ));
    }

    #[test]
    fn complete_coverage_rejects_blocked_issues() {
        let mut graph = complete_root_graph();
        graph.issues.push(AttachmentIssue {
            code: "fixture_blocked".to_string(),
            class: IssueClass::Policy,
            severity: IssueSeverity::Blocked,
            object_id: Some(graph.root.clone()),
            edge_index: None,
            safe_message: "The fixture is blocked.".to_string(),
        });

        assert!(matches!(
            graph.validate(),
            Err(ContractError::InvalidGraph(message))
                if message == "complete coverage cannot contain a blocked issue"
        ));
    }

    #[test]
    fn complete_coverage_rejects_incomplete_derivation_outcomes() {
        let mut graph = complete_root_graph();
        graph.edges.push(DerivationEdge {
            parent: graph.root.clone(),
            child: None,
            depth: 1,
            name: LogicalName::provided("encrypted.bin"),
            transform: TransformProvenance {
                kind: TransformKind::ZipMember,
                implementation: "fixture".to_string(),
                version: "1".to_string(),
            },
            declared_uncompressed_bytes: None,
            compressed_bytes: None,
            source_range: None,
            outcome: EdgeOutcome::Encrypted,
        });
        graph.usage.edges = 1;
        graph.usage.deepest_object = 1;

        assert!(matches!(
            graph.validate(),
            Err(ContractError::InvalidGraph(message))
                if message == "complete coverage cannot contain an incomplete derivation outcome"
        ));
    }

    #[test]
    fn source_ranges_must_fit_inside_the_parent_object() {
        let mut graph = complete_derived_graph();
        graph.edges[0].source_range = Some(ByteRange {
            start: 0,
            end_exclusive: 5,
        });

        assert!(matches!(
            graph.validate(),
            Err(ContractError::InvalidGraph(message))
                if message.contains("beyond parent")
        ));
    }

    #[test]
    fn every_non_root_object_requires_a_derived_provenance_edge() {
        let mut graph = complete_derived_graph();
        graph.edges[0].outcome = EdgeOutcome::Duplicate;

        assert!(matches!(
            graph.validate(),
            Err(ContractError::InvalidGraph(message))
                if message.contains("no provenance-establishing derived edge")
        ));
    }

    #[test]
    fn derived_byte_usage_cannot_understate_retained_objects() {
        let mut graph = complete_derived_graph();
        graph.usage.total_derived_bytes = 1;

        assert!(matches!(
            graph.validate(),
            Err(ContractError::InvalidGraph(message))
                if message.contains("smaller than the 2 bytes retained by derived objects")
        ));
    }

    #[test]
    fn derivation_edges_require_versioned_implementation_provenance() {
        let mut graph = complete_derived_graph();
        graph.edges[0].transform.version.clear();

        assert!(matches!(
            graph.validate(),
            Err(ContractError::InvalidGraph(message))
                if message.contains("implementation and version provenance")
        ));
    }

    #[test]
    fn real_objects_cannot_cross_depth_or_per_object_byte_limits() {
        let mut too_deep = complete_derived_graph();
        too_deep.limits.max_depth = 0;
        assert!(matches!(
            too_deep.validate(),
            Err(ContractError::DepthOutOfRange(1))
        ));

        let mut too_large = complete_derived_graph();
        too_large.limits.max_object_bytes = 1;
        too_large.limits.max_total_derived_bytes = 1;
        assert!(matches!(
            too_large.validate(),
            Err(ContractError::InvalidGraph(message))
                if message.contains("per-object limit")
        ));
    }

    #[test]
    fn only_childless_depth_rejection_may_record_max_depth_plus_one() {
        let mut graph = complete_root_graph();
        graph.limits.max_depth = 0;
        graph.edges.push(DerivationEdge {
            parent: graph.root.clone(),
            child: None,
            depth: 1,
            name: LogicalName::provided("too-deep.bin"),
            transform: TransformProvenance {
                kind: TransformKind::ZipMember,
                implementation: "fixture".to_string(),
                version: "1".to_string(),
            },
            declared_uncompressed_bytes: None,
            compressed_bytes: None,
            source_range: None,
            outcome: EdgeOutcome::DepthExceeded,
        });
        graph.usage.edges = 1;
        graph.usage.deepest_object = 1;
        graph.coverage = Coverage::Partial {
            reasons: vec!["depth_limit".to_string()],
        };

        assert_eq!(graph.validate(), Ok(()));
        graph.edges[0].outcome = EdgeOutcome::Malformed;
        assert!(matches!(
            graph.validate(),
            Err(ContractError::DepthOutOfRange(1))
        ));
    }
}
