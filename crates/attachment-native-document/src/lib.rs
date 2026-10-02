#![forbid(unsafe_code)]

//! Deterministic, bounded conversion of inspected attachment objects into
//! canonical text, media, and opaque artifacts.
//!
//! This crate receives only the content-addressed bytes retained by
//! `attachment-native-inspect`. It never opens a path, follows a link, opens
//! the network, starts a process, or re-extracts an archive. Office and EPUB
//! processors consume the already-derived object graph, preserving the
//! inspector's single monotonic decompression budget and provenance.

mod exports;
mod media;
mod office;
mod pdf;
mod rtf;
mod text;

use attachment_native_types::{
    ARTIFACT_SCHEMA, ArtifactId, ArtifactPayload, AttachmentBundle, AttachmentError,
    AttachmentIssue, BlobRef, BlobValidation, CanonicalArtifact, ContentTrust, Coverage,
    DetectedFormat, IssueClass, IssueSeverity, ObjectId, ObjectStatus, ProcessorProvenance,
    SegmentKind, TextFormat, TextSegment,
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

const PROCESSOR: &str = "attachment-native-document";
const VERSION: &str = env!("CARGO_PKG_VERSION");
const TEXT_BUDGET_WARNING: &str =
    "Canonical text was truncated at the global attachment text-byte limit.";

/// Processor-local limits. The graph's global byte limits remain authoritative;
/// these limits bound parser work within that already-inspected graph.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct DocumentLimits {
    pub max_processor_input_bytes: usize,
    pub max_pdf_input_bytes: usize,
    pub max_pdf_pages: u32,
    pub max_pdf_page_decompressed_bytes: usize,
    pub max_xml_events: u64,
    pub max_total_xml_events: u64,
    pub max_xml_depth: u32,
    pub max_csv_rows: u32,
    pub max_csv_cells: u64,
    pub max_notebook_cells: u32,
    pub max_html_depth: usize,
    pub max_segments: u32,
}

impl Default for DocumentLimits {
    fn default() -> Self {
        Self {
            max_processor_input_bytes: 16 * 1024 * 1024,
            max_pdf_input_bytes: 64 * 1024 * 1024,
            max_pdf_pages: 512,
            max_pdf_page_decompressed_bytes: 8 * 1024 * 1024,
            max_xml_events: 1_000_000,
            max_total_xml_events: 4_000_000,
            max_xml_depth: 256,
            max_csv_rows: 100_000,
            max_csv_cells: 1_000_000,
            max_notebook_cells: 10_000,
            max_html_depth: 256,
            max_segments: 100_000,
        }
    }
}

impl DocumentLimits {
    fn validate(&self) -> Result<(), AttachmentError> {
        if self.max_processor_input_bytes == 0
            || self.max_pdf_pages == 0
            || self.max_pdf_input_bytes == 0
            || self.max_pdf_page_decompressed_bytes == 0
            || self.max_xml_events == 0
            || self.max_total_xml_events == 0
            || self.max_xml_depth == 0
            || self.max_csv_rows == 0
            || self.max_csv_cells == 0
            || self.max_notebook_cells == 0
            || self.max_html_depth == 0
            || self.max_segments == 0
        {
            return Err(AttachmentError::blocked(
                "document_limits_invalid",
                "Every document processor limit must be greater than zero.",
            ));
        }
        Ok(())
    }

    fn bounded_by_graph(&self, max_parser_input_bytes: u64) -> Self {
        let graph_limit = usize::try_from(max_parser_input_bytes).unwrap_or(usize::MAX);
        let mut bounded = self.clone();
        bounded.max_processor_input_bytes = bounded.max_processor_input_bytes.min(graph_limit);
        bounded.max_pdf_input_bytes = bounded.max_pdf_input_bytes.min(graph_limit);
        bounded
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CanonicalizationSummary {
    pub artifact_ids: Vec<ArtifactId>,
    pub warnings: Vec<String>,
    pub text_bytes: u64,
    pub media_objects: u32,
    pub media_bytes: u64,
}

#[derive(Debug, Clone, Default)]
pub struct DocumentCanonicalizer {
    limits: DocumentLimits,
}

impl DocumentCanonicalizer {
    pub fn new(limits: DocumentLimits) -> Result<Self, AttachmentError> {
        limits.validate()?;
        Ok(Self { limits })
    }

    #[must_use]
    pub fn limits(&self) -> &DocumentLimits {
        &self.limits
    }

    /// Canonicalizes every eligible object once and updates each source
    /// `ObjectRecord.artifact_ids` in the same operation.
    ///
    /// Calling this method again is idempotent for this processor: prior
    /// artifacts from this processor are removed before deterministic IDs are
    /// regenerated. Artifacts owned by other processors are preserved.
    pub fn canonicalize(
        &self,
        bundle: &mut AttachmentBundle,
        policy_fingerprint: &str,
    ) -> Result<CanonicalizationSummary, AttachmentError> {
        let now = Instant::now();
        let deadline = now
            .checked_add(Duration::from_millis(bundle.graph.limits.deadline_ms))
            .unwrap_or(now);
        self.canonicalize_until(bundle, policy_fingerprint, deadline)
    }

    /// Canonicalizes against a caller-owned absolute deadline so an embedding
    /// host can share one monotonic wall-clock budget across inspection,
    /// canonicalization, and planning.
    pub fn canonicalize_until(
        &self,
        bundle: &mut AttachmentBundle,
        policy_fingerprint: &str,
        deadline: Instant,
    ) -> Result<CanonicalizationSummary, AttachmentError> {
        self.limits.validate()?;
        if policy_fingerprint.trim().is_empty() {
            return Err(AttachmentError::blocked(
                "document_policy_fingerprint_missing",
                "Document canonicalization requires a non-empty policy fingerprint.",
            ));
        }
        bundle.validate().map_err(|error| AttachmentError {
            code: "document_input_contract_invalid".to_string(),
            class: IssueClass::Internal,
            safe_message: error.to_string(),
            object_id: None,
            retryable: false,
        })?;

        remove_prior_processor_outputs(bundle);
        let index = BundleIndex::new(bundle);
        let limits = self
            .limits
            .bounded_by_graph(bundle.graph.limits.max_parser_input_bytes);
        let mut state =
            CanonicalizationState::new(bundle, policy_fingerprint, self.limits.max_segments);
        let mut work_budget = CanonicalizationWorkBudget::new(&limits, deadline);

        for object in &index.objects {
            let source = object.id.clone();
            if let Err(failure) = work_budget.checkpoint() {
                state.render_result(source, Err(failure));
                break;
            }
            let format = object
                .detection
                .selected
                .unwrap_or(DetectedFormat::UnknownBinary);
            if let Some((code, class, message)) = parser_status_blocker(format, &object.status) {
                state.issue(code, class, IssueSeverity::Blocked, &source, message);
                continue;
            }
            let Some(bytes) = index.blobs.get(&source).map(AsRef::as_ref) else {
                state.issue(
                    "canonical_source_blob_missing",
                    IssueClass::Internal,
                    IssueSeverity::Blocked,
                    &source,
                    "An inspected object has no retained bytes for canonicalization.",
                );
                continue;
            };

            if index.claimed_structural_children.contains(&source) {
                continue;
            }

            if uses_structured_canonical_parser(format)
                && u64::try_from(bytes.len()).unwrap_or(u64::MAX)
                    > state.bundle.graph.limits.max_parser_input_bytes
            {
                state.issue(
                    "canonical_parser_input_limit_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    &source,
                    "Canonicalization did not parse this object because it exceeds the inspection graph's parser-input ceiling.",
                );
                continue;
            }

            let output_limit = state.remaining_text_bytes;
            let budget_source = source.clone();
            match format {
                DetectedFormat::PlainText
                | DetectedFormat::Markdown
                | DetectedFormat::WebVtt
                | DetectedFormat::SubRip => {
                    state.render_result(
                        source,
                        text::canonicalize_plain(bytes, format, &limits),
                    );
                }
                DetectedFormat::RichText => state.render_result(source, rtf::canonicalize(bytes, &limits, output_limit)),
                DetectedFormat::Json => {
                    state.render_result(source, text::canonicalize_json(bytes, &limits, output_limit));
                }
                DetectedFormat::Csv | DetectedFormat::Tsv => {
                    state.render_result(
                        source,
                        text::canonicalize_delimited(bytes, format, &limits, output_limit),
                    );
                }
                DetectedFormat::Html => {
                    state.render_result(source, text::canonicalize_html(bytes, &limits));
                }
                DetectedFormat::Xml => {
                    state.render_result(
                        source,
                        text::canonicalize_xml(
                            bytes,
                            "XML document",
                            &limits,
                            &mut work_budget,
                        ),
                    );
                }
                DetectedFormat::Svg => {
                    state.render_result(
                        source.clone(),
                        text::canonicalize_xml(
                            bytes,
                            "SVG image",
                            &limits,
                            &mut work_budget,
                        ),
                    );
                    state.emit_opaque_with_warnings(
                        source,
                        format.canonical_media_type(),
                        bytes,
                        vec!["SVG remains active untrusted XML and is not exposed as decoded raster media; a capability-aware planner may request rasterization or OCR.".to_string()],
                    );
                }
                DetectedFormat::JupyterNotebook => state.render_result(
                    source,
                    text::canonicalize_notebook(bytes, &limits, output_limit),
                ),
                DetectedFormat::Email => {
                    state.render_result(
                        source,
                        text::canonicalize_email(bytes, &limits, output_limit),
                    );
                }
                DetectedFormat::Pdf => {
                    let outcome = pdf::canonicalize_pdf(bytes, &limits, output_limit);
                    state.render_result(source.clone(), outcome.text);
                    state.emit_opaque_with_warnings(
                        source,
                        format.canonical_media_type(),
                        bytes,
                        outcome.opaque_warnings,
                    );
                }
                DetectedFormat::Docx => state.render_result(
                    source.clone(),
                    office::canonicalize_docx(
                        &source,
                        &index,
                        &limits,
                        output_limit,
                        &mut work_budget,
                    ),
                ),
                DetectedFormat::Pptx => state.render_result(
                    source.clone(),
                    office::canonicalize_pptx(
                        &source,
                        &index,
                        &limits,
                        output_limit,
                        &mut work_budget,
                    ),
                ),
                DetectedFormat::Xlsx => state.render_result(
                    source.clone(),
                    office::canonicalize_xlsx(
                        &source,
                        &index,
                        &limits,
                        output_limit,
                        &mut work_budget,
                    ),
                ),
                DetectedFormat::Epub => state.render_result(
                    source.clone(),
                    office::canonicalize_epub(
                        &source,
                        &index,
                        &limits,
                        output_limit,
                        &mut work_budget,
                    ),
                ),
                DetectedFormat::OpenDocumentText
                | DetectedFormat::OpenDocumentSpreadsheet
                | DetectedFormat::OpenDocumentPresentation => state.render_result(
                    source.clone(),
                    office::canonicalize_open_document(
                        &source,
                        format,
                        &index,
                        &limits,
                        output_limit,
                        &mut work_budget,
                    ),
                ),
                format if format.media_family().is_some() => {
                    state.emit_validated_media(source, format, bytes);
                }
                DetectedFormat::Executable => state.emit_opaque_with_warnings(
                    source,
                    format.canonical_media_type(),
                    bytes,
                    vec!["Executable content is retained only as an opaque reference and must not be executed.".to_string()],
                ),
                other => state.emit_opaque_with_warnings(
                    source,
                    other.canonical_media_type(),
                    bytes,
                    vec!["No safe in-process canonical text representation is available; the bytes remain opaque.".to_string()],
                ),
            }
            if let Err(failure) = work_budget.checkpoint() {
                state.render_result(budget_source, Err(failure));
                break;
            }
        }

        let summary = state.finish();
        bundle.validate().map_err(|error| AttachmentError {
            code: "document_output_contract_invalid".to_string(),
            class: IssueClass::Internal,
            safe_message: error.to_string(),
            object_id: None,
            retryable: false,
        })?;
        Ok(summary)
    }
}

#[derive(Debug, Clone)]
pub(crate) struct RenderedDocument {
    pub format: TextFormat,
    pub text: String,
    pub segments: Vec<TextSegment>,
    pub warnings: Vec<String>,
    pub issues: Vec<ProcessorFailure>,
    pub output_budget_exhausted: bool,
}

impl RenderedDocument {
    pub(crate) fn document(format: TextFormat, text: String) -> Self {
        let end_byte = text.len();
        Self {
            format,
            text,
            segments: vec![TextSegment {
                kind: SegmentKind::Document,
                label: None,
                start_byte: 0,
                end_byte,
                coordinates: None,
            }],
            warnings: Vec::new(),
            issues: Vec::new(),
            output_budget_exhausted: false,
        }
    }

    pub(crate) fn record_issue(&mut self, failure: ProcessorFailure) {
        if !self
            .warnings
            .iter()
            .any(|warning| warning == &failure.safe_message)
        {
            self.warnings.push(failure.safe_message.clone());
        }
        if !self.issues.iter().any(|existing| {
            existing.code == failure.code
                && existing.safe_message == failure.safe_message
                && existing.warning == failure.warning
        }) {
            self.issues.push(failure);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct AppendedSpan {
    pub start: usize,
    pub end: usize,
    pub complete: bool,
}

/// A UTF-8-aware accumulator whose allocation can never grow beyond the
/// caller's remaining canonical-text budget.
pub(crate) struct BoundedText {
    text: String,
    max_bytes: usize,
    truncated: bool,
}

impl BoundedText {
    pub(crate) fn new(max_bytes: usize) -> Self {
        Self {
            text: String::new(),
            max_bytes,
            truncated: false,
        }
    }

    pub(crate) fn push(&mut self, value: &str) -> AppendedSpan {
        let start = self.text.len();
        if self.truncated {
            return AppendedSpan {
                start,
                end: start,
                complete: false,
            };
        }
        let remaining = self.max_bytes.saturating_sub(start);
        let retained = utf8_prefix_len(value, remaining);
        self.text.push_str(&value[..retained]);
        let complete = retained == value.len();
        self.truncated |= !complete;
        AppendedSpan {
            start,
            end: self.text.len(),
            complete,
        }
    }

    pub(crate) fn len(&self) -> usize {
        self.text.len()
    }

    pub(crate) fn remaining(&self) -> usize {
        self.max_bytes.saturating_sub(self.text.len())
    }

    pub(crate) fn mark_truncated(&mut self) {
        self.truncated = true;
    }

    pub(crate) fn was_truncated(&self) -> bool {
        self.truncated
    }

    pub(crate) fn into_string(self) -> String {
        self.text
    }
}

pub(crate) type RenderResult = Result<Option<RenderedDocument>, ProcessorFailure>;

#[derive(Debug, Clone)]
pub(crate) struct ProcessorFailure {
    pub code: &'static str,
    pub safe_message: String,
    pub warning: bool,
}

impl ProcessorFailure {
    pub(crate) fn malformed(code: &'static str, safe_message: impl Into<String>) -> Self {
        Self {
            code,
            safe_message: safe_message.into(),
            warning: false,
        }
    }

    pub(crate) fn partial(code: &'static str, safe_message: impl Into<String>) -> Self {
        Self {
            code,
            safe_message: safe_message.into(),
            warning: true,
        }
    }
}

pub(crate) struct CanonicalizationWorkBudget {
    remaining_xml_events: u64,
    deadline: Instant,
    exhausted: Option<CanonicalizationLimit>,
}

#[derive(Debug, Clone, Copy)]
enum CanonicalizationLimit {
    Deadline,
    XmlEvents,
}

impl CanonicalizationWorkBudget {
    fn new(limits: &DocumentLimits, deadline: Instant) -> Self {
        Self {
            remaining_xml_events: limits.max_total_xml_events,
            deadline,
            exhausted: None,
        }
    }

    pub(crate) fn checkpoint(&mut self) -> Result<(), ProcessorFailure> {
        if let Some(limit) = self.exhausted {
            return Err(limit.failure());
        }
        if Instant::now() >= self.deadline {
            self.exhausted = Some(CanonicalizationLimit::Deadline);
            return Err(CanonicalizationLimit::Deadline.failure());
        }
        Ok(())
    }

    pub(crate) fn charge_xml_event(&mut self) -> Result<(), ProcessorFailure> {
        self.checkpoint()?;
        if self.remaining_xml_events == 0 {
            self.exhausted = Some(CanonicalizationLimit::XmlEvents);
            return Err(CanonicalizationLimit::XmlEvents.failure());
        }
        self.remaining_xml_events = self.remaining_xml_events.saturating_sub(1);
        Ok(())
    }

    fn exhausted_failure(&self) -> Option<ProcessorFailure> {
        self.exhausted.map(CanonicalizationLimit::failure)
    }
}

impl CanonicalizationLimit {
    fn failure(self) -> ProcessorFailure {
        match self {
            Self::Deadline => ProcessorFailure::partial(
                "processing_deadline_exceeded",
                "Document canonicalization stopped at the configured processing deadline.",
            ),
            Self::XmlEvents => ProcessorFailure::partial(
                "total_xml_event_limit_exceeded",
                "Document canonicalization stopped at the shared XML event limit.",
            ),
        }
    }
}

pub(crate) struct BundleIndex {
    objects: Vec<attachment_native_types::ObjectRecord>,
    blobs: BTreeMap<ObjectId, std::sync::Arc<[u8]>>,
    children: BTreeMap<ObjectId, Vec<NamedChild>>,
    claimed_structural_children: BTreeSet<ObjectId>,
}

#[derive(Debug, Clone)]
pub(crate) struct NamedChild {
    pub name: String,
    pub id: ObjectId,
    pub bytes: std::sync::Arc<[u8]>,
}

impl BundleIndex {
    fn new(bundle: &AttachmentBundle) -> Self {
        let by_id = bundle
            .graph
            .objects
            .iter()
            .map(|object| (&object.id, object))
            .collect::<BTreeMap<_, _>>();
        let mut children: BTreeMap<ObjectId, Vec<NamedChild>> = BTreeMap::new();
        let mut claimed_structural_children = BTreeSet::new();
        for edge in &bundle.graph.edges {
            let Some(child_id) = edge.child.as_ref() else {
                continue;
            };
            let Some(bytes) = bundle.blobs.get(child_id) else {
                continue;
            };
            let Some(_) = by_id.get(child_id) else {
                continue;
            };
            children
                .entry(edge.parent.clone())
                .or_default()
                .push(NamedChild {
                    name: edge.name.display.clone(),
                    id: child_id.clone(),
                    bytes: bytes.clone(),
                });
        }
        for values in children.values_mut() {
            values.sort_by(|left, right| left.name.cmp(&right.name).then(left.id.cmp(&right.id)));
        }
        for object in &bundle.graph.objects {
            if matches!(
                object.detection.selected,
                Some(
                    DetectedFormat::Docx
                        | DetectedFormat::Pptx
                        | DetectedFormat::Xlsx
                        | DetectedFormat::Epub
                        | DetectedFormat::OpenDocumentText
                        | DetectedFormat::OpenDocumentSpreadsheet
                        | DetectedFormat::OpenDocumentPresentation
                )
            ) && let Some(values) = children.get(&object.id)
            {
                for child in values {
                    if office::is_structural_member(
                        object
                            .detection
                            .selected
                            .unwrap_or(DetectedFormat::UnknownBinary),
                        &child.name,
                    ) {
                        claimed_structural_children.insert(child.id.clone());
                    }
                }
            }
        }
        Self {
            objects: bundle.graph.objects.clone(),
            blobs: bundle.blobs.clone(),
            children,
            claimed_structural_children,
        }
    }

    pub(crate) fn children(&self, parent: &ObjectId) -> &[NamedChild] {
        self.children
            .get(parent)
            .map(Vec::as_slice)
            .unwrap_or_default()
    }
}

fn uses_structured_canonical_parser(format: DetectedFormat) -> bool {
    matches!(
        format,
        DetectedFormat::Json
            | DetectedFormat::Csv
            | DetectedFormat::Tsv
            | DetectedFormat::Html
            | DetectedFormat::Xml
            | DetectedFormat::Svg
            | DetectedFormat::JupyterNotebook
            | DetectedFormat::Email
            | DetectedFormat::Pdf
            | DetectedFormat::Docx
            | DetectedFormat::Pptx
            | DetectedFormat::Xlsx
            | DetectedFormat::Epub
            | DetectedFormat::OpenDocumentText
            | DetectedFormat::OpenDocumentSpreadsheet
            | DetectedFormat::OpenDocumentPresentation
    )
}

fn parser_status_blocker(
    format: DetectedFormat,
    status: &ObjectStatus,
) -> Option<(&'static str, IssueClass, String)> {
    match status {
        ObjectStatus::Complete => None,
        ObjectStatus::Partial { reasons }
            if reasons
                .iter()
                .all(|reason| partial_reason_allows_parser(format, reason)) =>
        {
            None
        }
        ObjectStatus::Partial { reasons } => Some((
            "canonical_parser_source_partial",
            IssueClass::Budget,
            format!(
                "Canonicalization did not parse this partial inspection object because its status does not establish parser-safe coverage: {}.",
                reasons.join(", ")
            ),
        )),
        ObjectStatus::Unsupported { code } => Some((
            "canonical_parser_source_unsupported",
            IssueClass::Unsupported,
            format!(
                "Canonicalization did not promote an object inspection marked unsupported ({code})."
            ),
        )),
        ObjectStatus::Blocked { code } => Some((
            "canonical_parser_source_blocked",
            IssueClass::Policy,
            format!(
                "Canonicalization did not promote an object inspection marked blocked ({code})."
            ),
        )),
        ObjectStatus::Malformed { code } => Some((
            "canonical_parser_source_malformed",
            IssueClass::Malformed,
            format!(
                "Canonicalization did not parse an object inspection marked malformed ({code})."
            ),
        )),
        ObjectStatus::Opaque if format == DetectedFormat::UnknownBinary => None,
        ObjectStatus::Opaque => Some((
            "canonical_parser_source_opaque",
            IssueClass::Unsupported,
            "Canonicalization did not promote an object whose inspection coverage is opaque."
                .to_string(),
        )),
    }
}

fn partial_reason_allows_parser(format: DetectedFormat, reason: &str) -> bool {
    // These reasons concern embedded-file derivation only. The inspector has
    // already completed strict parsing of the containing PDF, so canonical
    // page text extraction remains bounded and useful while coverage remains
    // honestly partial. Every other partial reason fails closed.
    format == DetectedFormat::Pdf && reason == "pdf_embedded_file_inspection_disabled"
}

struct CanonicalizationState<'a> {
    bundle: &'a mut AttachmentBundle,
    policy_fingerprint: &'a str,
    remaining_text_bytes: usize,
    remaining_segments: u32,
    summary: CanonicalizationSummary,
    partial_reasons: BTreeSet<String>,
}

impl<'a> CanonicalizationState<'a> {
    fn new(
        bundle: &'a mut AttachmentBundle,
        policy_fingerprint: &'a str,
        max_segments: u32,
    ) -> Self {
        let max_text = usize::try_from(bundle.graph.limits.max_text_bytes).unwrap_or(usize::MAX);
        let used_text = usize::try_from(bundle.graph.usage.text_bytes).unwrap_or(usize::MAX);
        Self {
            remaining_text_bytes: max_text.saturating_sub(used_text),
            remaining_segments: max_segments,
            bundle,
            policy_fingerprint,
            summary: CanonicalizationSummary::default(),
            partial_reasons: BTreeSet::new(),
        }
    }

    fn render_result(&mut self, source: ObjectId, result: RenderResult) {
        match result {
            Ok(Some(document)) => self.emit_text(source, document),
            Ok(None) => self.issue(
                "canonical_text_empty",
                IssueClass::Unsupported,
                IssueSeverity::Warning,
                &source,
                "The document contained no recoverable text; its inspected bytes remain available for capability-aware handling.",
            ),
            Err(failure) => self.issue(
                failure.code,
                if failure.warning {
                    IssueClass::Budget
                } else {
                    IssueClass::Malformed
                },
                if failure.warning {
                    IssueSeverity::Warning
                } else {
                    IssueSeverity::Blocked
                },
                &source,
                failure.safe_message,
            ),
        }
    }

    fn emit_text(&mut self, source: ObjectId, mut document: RenderedDocument) {
        for failure in std::mem::take(&mut document.issues) {
            self.issue(
                failure.code,
                if failure.warning {
                    IssueClass::Budget
                } else {
                    IssueClass::Malformed
                },
                if failure.warning {
                    IssueSeverity::Warning
                } else {
                    IssueSeverity::Blocked
                },
                &source,
                failure.safe_message,
            );
        }
        let mut budget_exhausted = document.output_budget_exhausted;
        if document.text.is_empty() {
            if budget_exhausted {
                self.issue(
                    "canonical_text_budget_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Warning,
                    &source,
                    TEXT_BUDGET_WARNING,
                );
                return;
            }
            self.issue(
                "canonical_text_empty",
                IssueClass::Unsupported,
                IssueSeverity::Warning,
                &source,
                "The document contained no recoverable text.",
            );
            return;
        }
        let original_len = document.text.len();
        if document.text.len() > self.remaining_text_bytes {
            let end = utf8_prefix_len(&document.text, self.remaining_text_bytes);
            document.text.truncate(end);
            budget_exhausted = true;
        }
        if budget_exhausted {
            if !document
                .warnings
                .iter()
                .any(|warning| warning == TEXT_BUDGET_WARNING)
            {
                document.warnings.push(TEXT_BUDGET_WARNING.to_string());
            }
            self.issue(
                "canonical_text_budget_exceeded",
                IssueClass::Budget,
                IssueSeverity::Warning,
                &source,
                TEXT_BUDGET_WARNING,
            );
        }
        document.segments.retain_mut(|segment| {
            if segment.start_byte >= document.text.len() {
                return false;
            }
            segment.end_byte = segment.end_byte.min(document.text.len());
            segment.start_byte <= segment.end_byte
                && document.text.is_char_boundary(segment.start_byte)
                && document.text.is_char_boundary(segment.end_byte)
        });
        if document.segments.len() > usize::try_from(self.remaining_segments).unwrap_or(0) {
            let keep = usize::try_from(self.remaining_segments).unwrap_or(0);
            document.segments.truncate(keep);
            document
                .warnings
                .push("Text segment metadata was truncated at the configured segment limit; text content remains authoritative.".to_string());
            self.issue(
                "canonical_segment_limit_exceeded",
                IssueClass::Budget,
                IssueSeverity::Warning,
                &source,
                "Text segment metadata was truncated at the configured segment limit.",
            );
        }
        if document.text.is_empty() && original_len > 0 {
            return;
        }
        self.remaining_segments = self
            .remaining_segments
            .saturating_sub(u32::try_from(document.segments.len()).unwrap_or(u32::MAX));
        self.remaining_text_bytes = self
            .remaining_text_bytes
            .saturating_sub(document.text.len());
        self.summary.text_bytes = self
            .summary
            .text_bytes
            .saturating_add(u64::try_from(document.text.len()).unwrap_or(u64::MAX));
        let payload = ArtifactPayload::Text {
            format: document.format,
            text: document.text,
            segments: document.segments,
        };
        self.emit(source, payload, document.warnings);
    }

    fn emit_validated_media(&mut self, source: ObjectId, format: DetectedFormat, bytes: &[u8]) {
        let Some(family) = format.media_family() else {
            return;
        };
        let probe =
            match media::probe_media(format, bytes, self.bundle.graph.limits.max_image_pixels) {
                Ok(probe) => probe,
                Err(message) => {
                    self.emit_opaque_with_warnings(
                        source.clone(),
                        format.canonical_media_type(),
                        bytes,
                        vec![message.to_string()],
                    );
                    self.issue(
                        "media_structural_probe_failed",
                        IssueClass::Malformed,
                        IssueSeverity::Warning,
                        &source,
                        message,
                    );
                    return;
                }
            };
        let byte_len = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        let next_objects = self.bundle.graph.usage.media_objects.saturating_add(1);
        let next_bytes = self.bundle.graph.usage.media_bytes.saturating_add(byte_len);
        if next_objects > self.bundle.graph.limits.max_media_objects
            || next_bytes > self.bundle.graph.limits.max_media_bytes
        {
            self.issue(
                "canonical_media_budget_exceeded",
                IssueClass::Budget,
                IssueSeverity::Warning,
                &source,
                "A media object remains in the graph but was not exposed as a model artifact because the global media budget was exhausted.",
            );
            return;
        }
        self.bundle.graph.usage.media_objects = next_objects;
        self.bundle.graph.usage.media_bytes = next_bytes;
        self.summary.media_objects = self.summary.media_objects.saturating_add(1);
        self.summary.media_bytes = self.summary.media_bytes.saturating_add(byte_len);
        self.emit(
            source.clone(),
            ArtifactPayload::Media {
                family,
                blob: blob_ref(&source, format.canonical_media_type(), bytes),
                metadata: probe.metadata,
                validation: BlobValidation {
                    grade: probe.grade,
                    method: probe.method.to_string(),
                    validator: ProcessorProvenance {
                        name: PROCESSOR.to_string(),
                        version: VERSION.to_string(),
                        policy_fingerprint: self.policy_fingerprint.to_string(),
                    },
                },
            },
            Vec::new(),
        );
    }

    fn emit_opaque_with_warnings(
        &mut self,
        source: ObjectId,
        media_type: &str,
        bytes: &[u8],
        warnings: Vec<String>,
    ) {
        self.emit(
            source.clone(),
            ArtifactPayload::Opaque {
                blob: blob_ref(&source, media_type, bytes),
            },
            warnings,
        );
    }

    fn emit(&mut self, source: ObjectId, payload: ArtifactPayload, warnings: Vec<String>) {
        let id = deterministic_artifact_id(&source, self.policy_fingerprint, &payload);
        let artifact = CanonicalArtifact {
            schema: ARTIFACT_SCHEMA.to_string(),
            id: id.clone(),
            source: source.clone(),
            processor: ProcessorProvenance {
                name: PROCESSOR.to_string(),
                version: VERSION.to_string(),
                policy_fingerprint: self.policy_fingerprint.to_string(),
            },
            trust: ContentTrust::UntrustedAttachmentData,
            payload,
            warnings: warnings.clone(),
        };
        if let Some(object) = self
            .bundle
            .graph
            .objects
            .iter_mut()
            .find(|object| object.id == source)
            && !object.artifact_ids.contains(&id)
        {
            object.artifact_ids.push(id.clone());
            object.artifact_ids.sort();
        }
        self.summary.artifact_ids.push(id);
        self.summary.warnings.extend(warnings);
        self.bundle.artifacts.push(artifact);
    }

    fn issue(
        &mut self,
        code: &str,
        class: IssueClass,
        severity: IssueSeverity,
        source: &ObjectId,
        message: impl Into<String>,
    ) {
        let code = if code.starts_with("canonical_") {
            code.to_string()
        } else {
            format!("canonical_{code}")
        };
        let message = message.into();
        self.summary.warnings.push(message.clone());
        let issue = AttachmentIssue {
            code: code.clone(),
            class,
            severity,
            object_id: Some(source.clone()),
            edge_index: None,
            safe_message: message,
        };
        if !self.bundle.graph.issues.contains(&issue) {
            self.bundle.graph.issues.push(issue);
        }
        self.partial_reasons.insert(code);
    }

    fn finish(mut self) -> CanonicalizationSummary {
        self.bundle.graph.usage.text_bytes = self
            .bundle
            .graph
            .usage
            .text_bytes
            .saturating_add(self.summary.text_bytes);
        if !self.partial_reasons.is_empty() {
            let mut reasons = match &self.bundle.graph.coverage {
                Coverage::Complete => BTreeSet::new(),
                Coverage::Partial { reasons } => reasons.iter().cloned().collect(),
            };
            reasons.append(&mut self.partial_reasons);
            self.bundle.graph.coverage = Coverage::Partial {
                reasons: reasons.into_iter().collect(),
            };
        }
        self.bundle
            .artifacts
            .sort_by(|left, right| left.id.cmp(&right.id));
        self.summary.artifact_ids.sort();
        self.summary.warnings.sort();
        self.summary.warnings.dedup();
        self.summary
    }
}

fn remove_prior_processor_outputs(bundle: &mut AttachmentBundle) {
    let removed = bundle
        .artifacts
        .iter()
        .filter(|artifact| artifact.processor.name == PROCESSOR)
        .map(|artifact| {
            let (text_bytes, media_objects, media_bytes) = match &artifact.payload {
                ArtifactPayload::Text { text, .. } => {
                    (u64::try_from(text.len()).unwrap_or(u64::MAX), 0, 0)
                }
                ArtifactPayload::Media { blob, .. } => (0, 1, blob.byte_len),
                ArtifactPayload::Opaque { .. } => (0, 0, 0),
            };
            (artifact.id.clone(), text_bytes, media_objects, media_bytes)
        })
        .collect::<Vec<_>>();
    let removed_ids = removed
        .iter()
        .map(|(id, _, _, _)| id)
        .collect::<BTreeSet<_>>();
    let removed_text = removed.iter().map(|(_, bytes, _, _)| *bytes).sum::<u64>();
    let removed_media_objects = removed.iter().map(|(_, _, count, _)| *count).sum::<u32>();
    let removed_media_bytes = removed.iter().map(|(_, _, _, bytes)| *bytes).sum::<u64>();
    bundle
        .artifacts
        .retain(|artifact| !removed_ids.contains(&artifact.id));
    for object in &mut bundle.graph.objects {
        object
            .artifact_ids
            .retain(|artifact_id| !removed_ids.contains(artifact_id));
    }
    bundle.graph.usage.text_bytes = bundle.graph.usage.text_bytes.saturating_sub(removed_text);
    bundle.graph.usage.media_objects = bundle
        .graph
        .usage
        .media_objects
        .saturating_sub(removed_media_objects);
    bundle.graph.usage.media_bytes = bundle
        .graph
        .usage
        .media_bytes
        .saturating_sub(removed_media_bytes);
    bundle
        .graph
        .issues
        .retain(|issue| !issue.code.starts_with("canonical_"));
    if let Coverage::Partial { reasons } = &mut bundle.graph.coverage {
        reasons.retain(|reason| !reason.starts_with("canonical_"));
        if reasons.is_empty() {
            bundle.graph.coverage = Coverage::Complete;
        }
    }
}

fn blob_ref(source: &ObjectId, media_type: &str, bytes: &[u8]) -> BlobRef {
    BlobRef {
        object_id: source.clone(),
        sha256: source.0.clone(),
        byte_len: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
        media_type: media_type.to_string(),
    }
}

fn deterministic_artifact_id(
    source: &ObjectId,
    policy_fingerprint: &str,
    payload: &ArtifactPayload,
) -> ArtifactId {
    let payload = serde_json::to_vec(payload).unwrap_or_default();
    let mut digest = Sha256::new();
    digest.update(b"attachment-native-artifact-v1\0");
    digest.update(source.0.as_bytes());
    digest.update(b"\0");
    digest.update(PROCESSOR.as_bytes());
    digest.update(b"\0");
    digest.update(VERSION.as_bytes());
    digest.update(b"\0");
    digest.update(policy_fingerprint.as_bytes());
    digest.update(b"\0");
    digest.update(payload);
    ArtifactId(format!("{:x}", digest.finalize()))
}

pub(crate) fn utf8_prefix_len(value: &str, max_bytes: usize) -> usize {
    let mut end = value.len().min(max_bytes);
    while !value.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    end
}

#[cfg(test)]
mod tests {
    use super::*;
    use attachment_native_inspect::{Inspector, ProvidedAttachment};
    use attachment_native_types::{
        AttachmentGraph, AttachmentJobId, BudgetLimits, BudgetUsage, Detection, GRAPH_SCHEMA,
        InspectionPolicy, LogicalName, ObjectRecord, ObjectStatus,
    };
    use sha2::{Digest, Sha256};
    use std::error::Error;
    use std::io::{Cursor, Write};
    use std::sync::Arc;
    use zip::write::SimpleFileOptions;

    fn one_object_bundle(format: DetectedFormat, bytes: &[u8]) -> AttachmentBundle {
        let hash = format!("{:x}", Sha256::digest(bytes));
        let id = ObjectId(hash.clone());
        let record = ObjectRecord {
            id: id.clone(),
            sha256: hash,
            byte_len: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
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
        };
        AttachmentBundle {
            graph: AttachmentGraph {
                schema: GRAPH_SCHEMA.to_string(),
                job_id: AttachmentJobId::new(),
                root: id.clone(),
                root_name: LogicalName::provided("fixture"),
                objects: vec![record],
                edges: Vec::new(),
                issues: Vec::new(),
                coverage: Coverage::Complete,
                limits: BudgetLimits::default(),
                usage: BudgetUsage {
                    root_bytes: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
                    retained_bytes: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
                    objects: 1,
                    ..BudgetUsage::default()
                },
            },
            artifacts: Vec::new(),
            blobs: BTreeMap::from([(id, Arc::from(bytes.to_vec()))]),
        }
    }

    #[test]
    fn artifact_ids_are_deterministic_and_bidirectional() -> Result<(), AttachmentError> {
        let mut first = one_object_bundle(DetectedFormat::PlainText, b"hello");
        let mut second = first.clone();
        let canonicalizer = DocumentCanonicalizer::default();
        let first_summary = canonicalizer.canonicalize(&mut first, "policy-v1")?;
        let second_summary = canonicalizer.canonicalize(&mut second, "policy-v1")?;
        assert_eq!(first_summary.artifact_ids, second_summary.artifact_ids);
        assert_eq!(
            first.graph.objects[0].artifact_ids,
            first_summary.artifact_ids
        );
        assert_eq!(first.validate(), Ok(()));
        Ok(())
    }

    #[test]
    fn repeated_canonicalization_is_idempotent() -> Result<(), AttachmentError> {
        let mut bundle = one_object_bundle(DetectedFormat::PlainText, b"hello");
        let canonicalizer = DocumentCanonicalizer::default();
        let first = canonicalizer.canonicalize(&mut bundle, "policy-v1")?;
        let usage = bundle.graph.usage.clone();
        let second = canonicalizer.canonicalize(&mut bundle, "policy-v1")?;
        assert_eq!(first.artifact_ids, second.artifact_ids);
        assert_eq!(bundle.artifacts.len(), 1);
        assert_eq!(bundle.graph.usage, usage);
        Ok(())
    }

    #[test]
    fn repeated_failures_replace_processor_issues_instead_of_accumulating()
    -> Result<(), AttachmentError> {
        let mut bundle = one_object_bundle(DetectedFormat::Json, b"{not-json");
        let canonicalizer = DocumentCanonicalizer::default();

        canonicalizer.canonicalize(&mut bundle, "policy-v1")?;
        canonicalizer.canonicalize(&mut bundle, "policy-v1")?;

        assert_eq!(
            bundle
                .graph
                .issues
                .iter()
                .filter(|issue| issue.code == "canonical_json_parse_failed")
                .count(),
            1
        );
        assert!(matches!(
            &bundle.graph.coverage,
            Coverage::Partial { reasons }
                if reasons == &["canonical_json_parse_failed".to_string()]
        ));
        Ok(())
    }

    #[test]
    fn resolved_processor_budget_issue_does_not_leave_stale_partial_coverage()
    -> Result<(), AttachmentError> {
        let mut bundle = one_object_bundle(DetectedFormat::PlainText, b"hello");
        bundle.graph.limits.max_text_bytes = 2;
        let canonicalizer = DocumentCanonicalizer::default();
        canonicalizer.canonicalize(&mut bundle, "small-budget")?;
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));

        bundle.graph.limits.max_text_bytes = 64;
        canonicalizer.canonicalize(&mut bundle, "larger-budget")?;

        assert_eq!(bundle.graph.coverage, Coverage::Complete);
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .all(|issue| !issue.code.starts_with("canonical_"))
        );
        assert_eq!(root_text(&bundle), Some("hello"));
        Ok(())
    }

    #[test]
    fn inspected_unknown_binary_becomes_an_opaque_canonical_reference()
    -> Result<(), AttachmentError> {
        let bytes = vec![0, 1, 2, 3, 4, 0xff, 0xfe, 0xfd, 0x80];
        let mut bundle = Inspector::default().inspect(ProvidedAttachment::from_bytes(
            "unknown.bin",
            None,
            bytes,
        ))?;
        let root = bundle.graph.root.clone();
        assert_eq!(
            bundle.graph.objects[0].detection.selected,
            Some(DetectedFormat::UnknownBinary)
        );
        assert_eq!(bundle.graph.objects[0].status, ObjectStatus::Opaque);

        DocumentCanonicalizer::default().canonicalize(&mut bundle, "opaque-policy")?;

        assert!(bundle.artifacts.iter().any(|artifact| {
            artifact.source == root && matches!(artifact.payload, ArtifactPayload::Opaque { .. })
        }));
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .all(|issue| issue.code != "canonical_parser_source_opaque")
        );
        assert_eq!(bundle.validate(), Ok(()));
        Ok(())
    }

    #[test]
    fn global_text_limit_truncates_on_utf8_boundary() -> Result<(), AttachmentError> {
        let mut bundle = one_object_bundle(DetectedFormat::PlainText, "aéz".as_bytes());
        bundle.graph.limits.max_text_bytes = 2;
        let canonicalizer = DocumentCanonicalizer::default();
        canonicalizer.canonicalize(&mut bundle, "policy-v1")?;
        let text = bundle
            .artifacts
            .iter()
            .find_map(|artifact| match &artifact.payload {
                ArtifactPayload::Text { text, .. } => Some(text.as_str()),
                _ => None,
            });
        assert_eq!(text, Some("a"));
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .any(|issue| { issue.code == "canonical_text_budget_exceeded" })
        );
        Ok(())
    }

    #[test]
    fn bounded_text_never_grows_past_its_utf8_budget() {
        let mut output = BoundedText::new(5);
        let first = output.push("ab");
        let second = output.push("éé");
        let third = output.push("ignored");

        assert_eq!(
            first,
            AppendedSpan {
                start: 0,
                end: 2,
                complete: true
            }
        );
        assert_eq!(
            second,
            AppendedSpan {
                start: 2,
                end: 4,
                complete: false
            }
        );
        assert_eq!(
            third,
            AppendedSpan {
                start: 4,
                end: 4,
                complete: false
            }
        );
        assert_eq!(output.len(), 4);
        assert!(output.was_truncated());
        assert_eq!(output.into_string(), "abé");
    }

    #[test]
    fn shared_xml_event_budget_is_monotonic_across_parts() {
        let limits = DocumentLimits {
            max_total_xml_events: 5,
            ..DocumentLimits::default()
        };
        let mut work_budget =
            CanonicalizationWorkBudget::new(&limits, Instant::now() + Duration::from_secs(1));

        for _ in 0..5 {
            assert!(work_budget.charge_xml_event().is_ok());
        }
        let failure = work_budget
            .charge_xml_event()
            .expect_err("the sixth event must exceed the shared five-event budget");
        assert_eq!(failure.code, "total_xml_event_limit_exceeded");
        assert!(failure.warning);
    }

    #[test]
    fn expired_caller_deadline_blocks_before_parser_work() -> Result<(), AttachmentError> {
        let mut bundle = one_object_bundle(DetectedFormat::PlainText, b"must not be parsed");
        let canonicalizer = DocumentCanonicalizer::default();

        let summary =
            canonicalizer.canonicalize_until(&mut bundle, "expired-deadline", Instant::now())?;

        assert!(summary.artifact_ids.is_empty());
        assert!(bundle.artifacts.is_empty());
        assert!(bundle.graph.issues.iter().any(|issue| {
            issue.object_id.as_ref() == Some(&bundle.graph.root)
                && issue.code == "canonical_processing_deadline_exceeded"
                && issue.class == IssueClass::Budget
        }));
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
        Ok(())
    }

    #[test]
    fn inspection_parser_ceiling_cannot_be_bypassed_by_larger_document_limits()
    -> Result<(), AttachmentError> {
        let cases = [
            (
                "oversized.pdf",
                Some("application/pdf"),
                b"%PDF-1.7\nthis body deliberately exceeds the inspection parser ceiling\n%%EOF"
                    .as_slice(),
            ),
            (
                "oversized.eml",
                Some("message/rfc822"),
                b"From: sender@example.test\r\nTo: receiver@example.test\r\nSubject: bounded\r\n\r\nThis body deliberately exceeds the inspection parser ceiling."
                    .as_slice(),
            ),
        ];
        for (name, media_type, bytes) in cases {
            let mut policy = InspectionPolicy::default();
            policy.limits.max_parser_input_bytes = 24;
            let inspector = Inspector::new(policy)?;
            let mut bundle = inspector.inspect(ProvidedAttachment::from_bytes(
                name,
                media_type.map(str::to_string),
                bytes.to_vec(),
            ))?;
            assert!(matches!(
                bundle.graph.objects[0].status,
                ObjectStatus::Partial { ref reasons }
                    if reasons == &["parser_input_limit_exceeded".to_string()]
            ));
            let canonicalizer = DocumentCanonicalizer::new(DocumentLimits {
                max_processor_input_bytes: 1024 * 1024,
                max_pdf_input_bytes: 1024 * 1024,
                ..DocumentLimits::default()
            })?;
            let summary = canonicalizer.canonicalize(&mut bundle, "high-document-cap")?;
            assert!(summary.artifact_ids.is_empty());
            assert!(bundle.artifacts.is_empty());
            assert!(bundle.graph.objects[0].artifact_ids.is_empty());
            assert!(bundle.graph.issues.iter().any(|issue| {
                issue.object_id.as_ref() == Some(&bundle.graph.root)
                    && issue.code == "canonical_parser_source_partial"
            }));
        }
        Ok(())
    }

    fn zip_bytes(entries: &[(&str, &[u8])]) -> Result<Vec<u8>, Box<dyn Error>> {
        let mut output = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut output);
            for (name, bytes) in entries {
                writer.start_file(*name, SimpleFileOptions::default())?;
                writer.write_all(bytes)?;
            }
            let _ = writer.finish()?;
        }
        Ok(output.into_inner())
    }

    fn inspect_archive(name: &str, bytes: Vec<u8>) -> Result<AttachmentBundle, AttachmentError> {
        Inspector::default().inspect(ProvidedAttachment::from_bytes(name, None, bytes))
    }

    fn root_text(bundle: &AttachmentBundle) -> Option<&str> {
        bundle
            .artifacts
            .iter()
            .find(|artifact| artifact.source == bundle.graph.root)
            .and_then(|artifact| match &artifact.payload {
                ArtifactPayload::Text { text, .. } => Some(text.as_str()),
                _ => None,
            })
    }

    fn assert_successful_local_cap_is_partial(
        format: DetectedFormat,
        bytes: &[u8],
        limits: DocumentLimits,
        expected_issue: &str,
    ) -> Result<(), AttachmentError> {
        let mut bundle = one_object_bundle(format, bytes);
        DocumentCanonicalizer::new(limits)?.canonicalize(&mut bundle, "local-cap-test")?;
        assert!(
            bundle
                .artifacts
                .iter()
                .any(|artifact| artifact.source == bundle.graph.root),
            "the bounded parser should retain its useful canonical prefix"
        );
        assert!(bundle.graph.issues.iter().any(|issue| {
            issue.object_id.as_ref() == Some(&bundle.graph.root)
                && issue.code == expected_issue
                && issue.class == IssueClass::Budget
        }));
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
        Ok(())
    }

    #[test]
    fn every_successful_local_text_cap_marks_partial_coverage() -> Result<(), AttachmentError> {
        assert_successful_local_cap_is_partial(
            DetectedFormat::PlainText,
            b"useful prefix and omitted suffix",
            DocumentLimits {
                max_processor_input_bytes: 13,
                ..DocumentLimits::default()
            },
            "canonical_text_processor_input_limit",
        )?;
        assert_successful_local_cap_is_partial(
            DetectedFormat::Html,
            b"<p>useful prefix</p><p>omitted suffix</p>",
            DocumentLimits {
                max_processor_input_bytes: 20,
                ..DocumentLimits::default()
            },
            "canonical_html_processor_input_limit",
        )?;
        assert_successful_local_cap_is_partial(
            DetectedFormat::Html,
            b"<p>kept</p><div><div><div>omitted</div></div></div>",
            DocumentLimits {
                max_html_depth: 2,
                ..DocumentLimits::default()
            },
            "canonical_html_depth_limit_exceeded",
        )?;
        assert_successful_local_cap_is_partial(
            DetectedFormat::Csv,
            b"heading\nkept\nomitted\n",
            DocumentLimits {
                max_csv_rows: 1,
                ..DocumentLimits::default()
            },
            "canonical_delimited_row_or_cell_limit_exceeded",
        )?;
        assert_successful_local_cap_is_partial(
            DetectedFormat::JupyterNotebook,
            br#"{"cells":[{"cell_type":"markdown","source":["kept"]},{"cell_type":"markdown","source":["omitted"]}],"nbformat":4}"#,
            DocumentLimits {
                max_notebook_cells: 1,
                ..DocumentLimits::default()
            },
            "canonical_notebook_cell_limit_exceeded",
        )?;
        assert_successful_local_cap_is_partial(
            DetectedFormat::Xml,
            b"<x>kept</x>",
            DocumentLimits {
                max_xml_events: 3,
                ..DocumentLimits::default()
            },
            "canonical_xml_event_limit_exceeded",
        )?;
        Ok(())
    }

    #[test]
    fn docx_uses_inspected_children_without_reopening_the_archive() -> Result<(), Box<dyn Error>> {
        let bytes = zip_bytes(&[
            (
                "[Content_Types].xml",
                br#"<?xml version="1.0"?><Types></Types>"#,
            ),
            (
                "word/document.xml",
                br#"<?xml version="1.0"?><w:document xmlns:w="urn:w"><w:body><w:p><w:r><w:t>Hello from DOCX</w:t></w:r></w:p></w:body></w:document>"#,
            ),
        ])?;
        let mut bundle = inspect_archive("document.docx", bytes)?;
        assert_eq!(
            bundle.graph.objects[0].detection.selected,
            Some(DetectedFormat::Docx)
        );
        DocumentCanonicalizer::default().canonicalize(&mut bundle, "policy-v1")?;
        assert!(root_text(&bundle).is_some_and(|text| text.contains("Hello from DOCX")));
        let structural_children = bundle
            .graph
            .edges
            .iter()
            .filter(|edge| edge.parent == bundle.graph.root)
            .filter_map(|edge| edge.child.as_ref())
            .collect::<Vec<_>>();
        assert!(structural_children.iter().all(|id| {
            bundle
                .graph
                .objects
                .iter()
                .find(|object| &object.id == *id)
                .is_some_and(|object| object.artifact_ids.is_empty())
        }));
        bundle.validate()?;
        Ok(())
    }

    #[test]
    fn pptx_slides_are_naturally_ordered_and_segmented() -> Result<(), Box<dyn Error>> {
        let bytes = zip_bytes(&[
            ("[Content_Types].xml", b"<?xml version=\"1.0\"?><Types/>"),
            ("ppt/presentation.xml", b"<?xml version=\"1.0\"?><p:presentation xmlns:p=\"urn:p\"/>"),
            ("ppt/slides/slide10.xml", b"<?xml version=\"1.0\"?><p:sld xmlns:p=\"urn:p\" xmlns:a=\"urn:a\"><a:t>Ten</a:t></p:sld>"),
            ("ppt/slides/slide2.xml", b"<?xml version=\"1.0\"?><p:sld xmlns:p=\"urn:p\" xmlns:a=\"urn:a\"><a:t>Two</a:t></p:sld>"),
        ])?;
        let mut bundle = inspect_archive("slides.pptx", bytes)?;
        DocumentCanonicalizer::default().canonicalize(&mut bundle, "policy-v1")?;
        let text = root_text(&bundle).ok_or("PPTX root text missing")?;
        let two = text.find("## Slide 2").ok_or("slide 2 missing")?;
        let ten = text.find("## Slide 10").ok_or("slide 10 missing")?;
        assert!(two < ten);
        Ok(())
    }

    #[test]
    fn pptx_aggregate_is_bounded_before_state_emission() -> Result<(), Box<dyn Error>> {
        let bytes = zip_bytes(&[
            ("[Content_Types].xml", b"<?xml version=\"1.0\"?><Types/>"),
            ("ppt/presentation.xml", b"<?xml version=\"1.0\"?><p:presentation xmlns:p=\"urn:p\"/>"),
            ("ppt/slides/slide1.xml", "<?xml version=\"1.0\"?><p:sld xmlns:p=\"urn:p\" xmlns:a=\"urn:a\"><a:t>éééééééééééééééééééé</a:t></p:sld>".as_bytes()),
            ("ppt/slides/slide2.xml", b"<?xml version=\"1.0\"?><p:sld xmlns:p=\"urn:p\" xmlns:a=\"urn:a\"><a:t>This second slide must never be accumulated.</a:t></p:sld>"),
        ])?;
        let mut bundle = inspect_archive("bounded-slides.pptx", bytes)?;
        let source = bundle.graph.root.clone();
        let index = BundleIndex::new(&bundle);
        let max_output_bytes = 39;
        let limits = DocumentLimits::default();
        let mut work_budget =
            CanonicalizationWorkBudget::new(&limits, Instant::now() + Duration::from_secs(1));
        let document =
            office::canonicalize_pptx(&source, &index, &limits, max_output_bytes, &mut work_budget)
                .map_err(|error| std::io::Error::other(error.safe_message))?
                .ok_or("PPTX bounded output missing")?;

        assert!(document.output_budget_exhausted);
        assert!(document.text.len() <= max_output_bytes);
        assert!(document.text.is_char_boundary(document.text.len()));
        assert!(!document.text.contains("second slide"));
        assert!(document.segments.iter().all(|segment| {
            segment.start_byte <= segment.end_byte
                && segment.end_byte <= document.text.len()
                && document.text.is_char_boundary(segment.start_byte)
                && document.text.is_char_boundary(segment.end_byte)
        }));

        bundle.graph.limits.max_text_bytes = u64::try_from(max_output_bytes)?;
        DocumentCanonicalizer::default().canonicalize(&mut bundle, "bounded-output-test")?;
        assert!(bundle.graph.issues.iter().any(|issue| {
            issue.object_id.as_ref() == Some(&source)
                && issue.code == "canonical_text_budget_exceeded"
        }));
        Ok(())
    }

    #[test]
    fn xlsx_shared_strings_and_formulas_survive_container_pipeline() -> Result<(), Box<dyn Error>> {
        let bytes = zip_bytes(&[
            ("[Content_Types].xml", b"<?xml version=\"1.0\"?><Types/>"),
            ("xl/workbook.xml", b"<?xml version=\"1.0\"?><workbook/>"),
            ("xl/sharedStrings.xml", b"<?xml version=\"1.0\"?><sst><si><t>evidence</t></si></sst>"),
            ("xl/worksheets/sheet1.xml", br#"<?xml version="1.0"?><worksheet><sheetData><row><c r="A1" t="s"><v>0</v></c><c r="B1"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>"#),
        ])?;
        let mut bundle = inspect_archive("book.xlsx", bytes)?;
        DocumentCanonicalizer::default().canonicalize(&mut bundle, "policy-v1")?;
        let text = root_text(&bundle).ok_or("XLSX root text missing")?;
        assert!(text.contains("evidence"));
        assert!(text.contains("1+1"));
        Ok(())
    }

    #[test]
    fn epub_honors_spine_order_without_fetching_resources() -> Result<(), Box<dyn Error>> {
        let bytes = zip_bytes(&[
            ("META-INF/container.xml", br#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>"#),
            ("OPS/book.opf", br#"<?xml version="1.0"?><package><manifest><item id="second" href="two.xhtml"/><item id="first" href="one.xhtml"/></manifest><spine><itemref idref="first"/><itemref idref="second"/></spine></package>"#),
            ("OPS/two.xhtml", b"<html><body><h1>Second chapter</h1></body></html>"),
            ("OPS/one.xhtml", b"<html><body><h1>First chapter</h1><img src=\"https://example.invalid/x.png\"></body></html>"),
        ])?;
        let mut bundle = inspect_archive("book.epub", bytes)?;
        DocumentCanonicalizer::default().canonicalize(&mut bundle, "policy-v1")?;
        let text = root_text(&bundle).ok_or("EPUB root text missing")?;
        let first = text.find("First chapter").ok_or("first chapter missing")?;
        let second = text
            .find("Second chapter")
            .ok_or("second chapter missing")?;
        assert!(first < second);
        assert!(!text.contains("example.invalid"));
        Ok(())
    }

    #[test]
    fn open_document_text_uses_the_inspected_content_part() -> Result<(), Box<dyn Error>> {
        let bytes = zip_bytes(&[
            (
                "META-INF/manifest.xml",
                br#"<?xml version="1.0"?><manifest:manifest xmlns:manifest="urn:manifest"/>"#,
            ),
            (
                "content.xml",
                br#"<?xml version="1.0"?><office:document-content xmlns:office="urn:office" xmlns:text="urn:text"><office:body><office:text><text:h>Care plan</text:h><text:p>Grounded next step</text:p></office:text></office:body></office:document-content>"#,
            ),
            (
                "styles.xml",
                br#"<?xml version="1.0"?><office:document-styles xmlns:office="urn:office"/>"#,
            ),
        ])?;
        let mut bundle = inspect_archive("plan.odt", bytes)?;
        assert_eq!(
            bundle.graph.objects[0].detection.selected,
            Some(DetectedFormat::OpenDocumentText)
        );
        DocumentCanonicalizer::default().canonicalize(&mut bundle, "policy-v1")?;
        let text = root_text(&bundle).ok_or("ODT root text missing")?;
        assert!(text.contains("Care plan"));
        assert!(text.contains("Grounded next step"));
        assert!(bundle.validate().is_ok());
        Ok(())
    }

    #[test]
    fn malformed_docx_is_partial_and_never_fabricates_text() -> Result<(), Box<dyn Error>> {
        let bytes = zip_bytes(&[
            ("[Content_Types].xml", b"<?xml version=\"1.0\"?><Types/>"),
            (
                "word/document.xml",
                b"<?xml version=\"1.0\"?><w:document xmlns:w=\"urn:w\"><w:t>broken",
            ),
        ])?;
        let mut bundle = inspect_archive("broken.docx", bytes)?;
        DocumentCanonicalizer::default().canonicalize(&mut bundle, "policy-v1")?;
        assert!(root_text(&bundle).is_none());
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .any(|issue| { issue.code == "canonical_docx_text_extraction_failed" })
        );
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
        Ok(())
    }
}
