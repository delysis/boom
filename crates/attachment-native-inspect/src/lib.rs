#![forbid(unsafe_code)]

//! Content-first, bounded attachment inspection.
//!
//! The inspector accepts bytes already granted by its caller. It never opens a
//! path, writes an archive member, follows a link, opens the network, or starts
//! a process. Container traversal is iterative and uses one monotonic budget.

mod budget;
mod detect;
mod mbox;
mod mime_preflight;
mod path;
mod pdf;
mod pdf_preflight;
mod xz_preflight;
mod zip_preflight;

use attachment_native_types::{
    AttachmentBundle, AttachmentError, AttachmentGraph, AttachmentIssue, AttachmentJobId, Coverage,
    DerivationEdge, DetectedFormat, DetectionConfidence, DetectionEvidence, EdgeOutcome,
    FormatCandidate, GRAPH_SCHEMA, InspectionPolicy, IssueClass, IssueSeverity, LogicalName,
    ObjectId, ObjectRecord, ObjectStatus, TransformKind, TransformProvenance, UnknownBinaryPolicy,
};
use budget::BudgetLedger;
use detect::{classify_zip_members, detect};
use flate2::read::GzDecoder;
use libarchive_oxide::libarchive_oxide_core::{EntryKind, ErrorKind, Limits};
use libarchive_oxide::{ReaderEvent, SeekArchiveReader, StreamError};
use lopdf::{
    DecompressError, Document as PdfDocument, Error as PdfError, LoadOptions, Object as PdfObject,
};
use mail_parser::{MessageParser, MimeHeaders};
use path::logical_member_name;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::{Cursor, Read};
use std::sync::Arc;

const IMPLEMENTATION: &str = "attachment-native-inspect";
const VERSION: &str = env!("CARGO_PKG_VERSION");
const MAX_PDF_STRUCTURE_NODES: usize = 1_000_000;

#[derive(Debug, Clone)]
pub struct ProvidedAttachment {
    pub display_name: String,
    pub declared_media_type: Option<String>,
    pub bytes: Arc<[u8]>,
}

impl ProvidedAttachment {
    #[must_use]
    pub fn from_bytes(
        display_name: impl Into<String>,
        declared_media_type: Option<String>,
        bytes: impl Into<Vec<u8>>,
    ) -> Self {
        Self {
            display_name: display_name.into(),
            declared_media_type,
            bytes: Arc::from(bytes.into()),
        }
    }

    /// Read a caller-granted stream without trusting prior metadata or
    /// allocating from a declared length. The reader is consumed only through
    /// `max_root_bytes + 1`, so a growing file or dishonest length cannot
    /// bypass the root-byte gate.
    pub fn read_bounded(
        display_name: impl Into<String>,
        declared_media_type: Option<String>,
        mut reader: impl Read,
        max_root_bytes: u64,
    ) -> Result<Self, AttachmentError> {
        let probe_limit = max_root_bytes.checked_add(1).ok_or_else(|| {
            AttachmentError::budget(
                "root_bytes_overflow",
                "The root attachment limit cannot be represented safely.",
            )
        })?;
        let capacity = usize::try_from(max_root_bytes.min(1024 * 1024)).map_err(|_| {
            AttachmentError::budget(
                "root_bytes_overflow",
                "The root attachment limit cannot be represented safely.",
            )
        })?;
        let mut bytes = Vec::with_capacity(capacity);
        reader
            .by_ref()
            .take(probe_limit)
            .read_to_end(&mut bytes)
            .map_err(|_| AttachmentError {
                code: "attachment_read_failed".to_string(),
                class: IssueClass::Malformed,
                safe_message: "The granted attachment stream could not be read completely."
                    .to_string(),
                object_id: None,
                retryable: true,
            })?;
        let actual = u64::try_from(bytes.len()).map_err(|_| {
            AttachmentError::budget(
                "root_bytes_overflow",
                "The attachment length cannot be represented safely.",
            )
        })?;
        if actual > max_root_bytes {
            return Err(AttachmentError::budget(
                "root_bytes_exceeded",
                format!("The attachment exceeds the configured {max_root_bytes} byte root limit."),
            ));
        }
        Ok(Self::from_bytes(display_name, declared_media_type, bytes))
    }
}

/// The derived default is exactly the crate-owned, valid-by-construction
/// [`InspectionPolicy::default`]. User policies still go through [`Self::new`].
#[derive(Debug, Clone, Default)]
pub struct Inspector {
    policy: InspectionPolicy,
}

impl Inspector {
    pub fn new(policy: InspectionPolicy) -> Result<Self, AttachmentError> {
        policy.validate().map_err(|error| {
            AttachmentError::blocked("inspection_policy_invalid", error.to_string())
        })?;
        Ok(Self { policy })
    }

    #[must_use]
    pub fn policy(&self) -> &InspectionPolicy {
        &self.policy
    }

    pub fn inspect(&self, input: ProvidedAttachment) -> Result<AttachmentBundle, AttachmentError> {
        let mut state = InspectionState::new(self.policy.clone());
        state.insert_root(input)?;
        state.run()
    }
}

struct InspectionState {
    policy: InspectionPolicy,
    budget: BudgetLedger,
    job_id: AttachmentJobId,
    root: Option<ObjectId>,
    root_name: Option<LogicalName>,
    objects: Vec<ObjectRecord>,
    object_index: BTreeMap<ObjectId, usize>,
    edges: Vec<DerivationEdge>,
    blobs: BTreeMap<ObjectId, Arc<[u8]>>,
    queue: VecDeque<(ObjectId, u16)>,
    analyzed: BTreeSet<ObjectId>,
    issues: Vec<AttachmentIssue>,
    partial_reasons: BTreeSet<String>,
}

impl InspectionState {
    fn new(policy: InspectionPolicy) -> Self {
        Self {
            budget: BudgetLedger::new(policy.limits.clone()),
            policy,
            job_id: AttachmentJobId::new(),
            root: None,
            root_name: None,
            objects: Vec::new(),
            object_index: BTreeMap::new(),
            edges: Vec::new(),
            blobs: BTreeMap::new(),
            queue: VecDeque::new(),
            analyzed: BTreeSet::new(),
            issues: Vec::new(),
            partial_reasons: BTreeSet::new(),
        }
    }

    fn insert_root(&mut self, input: ProvidedAttachment) -> Result<(), AttachmentError> {
        let byte_len = u64::try_from(input.bytes.len()).map_err(|_| {
            AttachmentError::budget(
                "root_bytes_overflow",
                "The attachment length cannot be represented safely.",
            )
        })?;
        self.budget.charge_root(byte_len)?;
        let sha256 = sha256(&input.bytes);
        let id = ObjectId(sha256.clone());
        let detection = detect(
            &input.display_name,
            input.declared_media_type.as_deref(),
            &input.bytes,
        );
        if let Some(mismatch) = &detection.mismatch {
            self.issue(
                "declared_type_mismatch",
                IssueClass::Detection,
                IssueSeverity::Warning,
                Some(id.clone()),
                format!(
                    "The attachment name or declared type suggests {}, but its bytes indicate {}.",
                    mismatch.hint, mismatch.detected
                ),
                false,
            );
        }
        self.object_index.insert(id.clone(), 0);
        self.objects.push(ObjectRecord {
            id: id.clone(),
            sha256,
            byte_len,
            detection,
            status: ObjectStatus::Complete,
            first_depth: 0,
            artifact_ids: Vec::new(),
        });
        self.blobs.insert(id.clone(), input.bytes);
        self.queue.push_back((id.clone(), 0));
        self.root = Some(id);
        self.root_name = Some(LogicalName::provided(input.display_name));
        Ok(())
    }

    fn run(mut self) -> Result<AttachmentBundle, AttachmentError> {
        while let Some((object_id, depth)) = self.queue.pop_front() {
            self.budget.check_deadline()?;
            if !self.analyzed.insert(object_id.clone()) {
                continue;
            }
            let Some(bytes) = self.blobs.get(&object_id).cloned() else {
                return Err(AttachmentError {
                    code: "object_blob_missing".to_string(),
                    class: IssueClass::Internal,
                    safe_message: "An inspected object lost its content-addressed blob."
                        .to_string(),
                    object_id: Some(object_id),
                    retryable: false,
                });
            };
            let format = self.object(&object_id)?.detection.selected;
            if self.budget.derived_budget_exhausted() && format.is_some_and(format_can_derive) {
                self.set_status(
                    &object_id,
                    ObjectStatus::Partial {
                        reasons: vec!["total_derived_bytes_exceeded".to_string()],
                    },
                )?;
                self.issue(
                    "total_derived_bytes_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(object_id),
                    "The cumulative derived-byte budget is exhausted. This queued container was not opened or decoded.",
                    true,
                );
                continue;
            }
            let parser_input_bytes = u64::try_from(bytes.len()).map_err(|_| {
                AttachmentError::budget(
                    "parser_input_length_overflow",
                    "A parser input length cannot be represented safely.",
                )
            })?;
            if matches!(
                format,
                Some(
                    DetectedFormat::Zip
                        | DetectedFormat::Docx
                        | DetectedFormat::Pptx
                        | DetectedFormat::Xlsx
                        | DetectedFormat::Epub
                        | DetectedFormat::OpenDocumentText
                        | DetectedFormat::OpenDocumentSpreadsheet
                        | DetectedFormat::OpenDocumentPresentation
                        | DetectedFormat::IWorkPages
                        | DetectedFormat::IWorkNumbers
                        | DetectedFormat::IWorkKeynote
                        | DetectedFormat::Pdf
                        | DetectedFormat::Email
                        | DetectedFormat::Mbox
                        | DetectedFormat::SevenZip
                )
            ) && parser_input_bytes > self.policy.limits.max_parser_input_bytes
            {
                self.set_status(
                    &object_id,
                    ObjectStatus::Partial {
                        reasons: vec!["parser_input_limit_exceeded".to_string()],
                    },
                )?;
                self.issue(
                    "parser_input_limit_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(object_id),
                    format!(
                        "The structured parser input is {parser_input_bytes} bytes, exceeding the configured {} byte parser boundary.",
                        self.policy.limits.max_parser_input_bytes
                    ),
                    true,
                );
                continue;
            }
            match format {
                Some(
                    DetectedFormat::Zip
                    | DetectedFormat::Docx
                    | DetectedFormat::Pptx
                    | DetectedFormat::Xlsx
                    | DetectedFormat::Epub
                    | DetectedFormat::OpenDocumentText
                    | DetectedFormat::OpenDocumentSpreadsheet
                    | DetectedFormat::OpenDocumentPresentation
                    | DetectedFormat::IWorkPages
                    | DetectedFormat::IWorkNumbers
                    | DetectedFormat::IWorkKeynote,
                ) => self.expand_zip(&object_id, depth, &bytes),
                Some(DetectedFormat::Tar) => self.expand_tar(&object_id, depth, &bytes),
                Some(DetectedFormat::Gzip) => self.expand_gzip(&object_id, depth, &bytes),
                Some(DetectedFormat::Bzip2) => self.expand_bzip2(&object_id, depth, &bytes),
                Some(DetectedFormat::Xz) => self.expand_xz(&object_id, depth, &bytes),
                Some(DetectedFormat::Zstd) => self.expand_zstd(&object_id, depth, &bytes),
                Some(DetectedFormat::SevenZip) => self.expand_seven_zip(&object_id, depth, &bytes),
                Some(DetectedFormat::Email) => self.expand_email(&object_id, depth, &bytes),
                Some(DetectedFormat::Mbox) => self.expand_mbox(&object_id, depth, &bytes),
                Some(DetectedFormat::Pdf) => self.expand_pdf(&object_id, depth, &bytes),
                Some(DetectedFormat::Rar | DetectedFormat::OleCompound) => {
                    self.mark_unsupported_container(&object_id, format)
                }
                Some(DetectedFormat::Executable) => {
                    self.set_status(
                        &object_id,
                        ObjectStatus::Blocked {
                            code: "executable_content_blocked".to_string(),
                        },
                    )?;
                    self.issue(
                        "executable_content_blocked",
                        IssueClass::Policy,
                        IssueSeverity::Blocked,
                        Some(object_id),
                        "Executable attachment content is retained for provenance but is not prepared for a model.",
                        true,
                    );
                }
                Some(DetectedFormat::UnknownBinary) | None => match self.policy.unknown_binary {
                    UnknownBinaryPolicy::Reject => {
                        self.set_status(
                            &object_id,
                            ObjectStatus::Unsupported {
                                code: "unknown_binary_rejected".to_string(),
                            },
                        )?;
                        self.issue(
                            "unknown_binary_rejected",
                            IssueClass::Unsupported,
                            IssueSeverity::Blocked,
                            Some(object_id),
                            "The attachment format could not be established from its bytes.",
                            true,
                        );
                    }
                    UnknownBinaryPolicy::RecordOpaque => {
                        self.set_status(&object_id, ObjectStatus::Opaque)?;
                        self.issue(
                            "unknown_binary_recorded",
                            IssueClass::Unsupported,
                            IssueSeverity::Warning,
                            Some(object_id),
                            "The attachment format is unknown; its bytes remain opaque and will not be sent to a model by default.",
                            true,
                        );
                    }
                },
                _ => {}
            }
        }

        let root = self.root.ok_or_else(|| AttachmentError {
            code: "root_object_missing".to_string(),
            class: IssueClass::Internal,
            safe_message: "Attachment inspection did not retain its root object.".to_string(),
            object_id: None,
            retryable: false,
        })?;
        let root_name = self.root_name.ok_or_else(|| AttachmentError {
            code: "root_name_missing".to_string(),
            class: IssueClass::Internal,
            safe_message: "Attachment inspection did not retain its root name.".to_string(),
            object_id: Some(root.clone()),
            retryable: false,
        })?;
        let coverage = if self.partial_reasons.is_empty() {
            Coverage::Complete
        } else {
            Coverage::Partial {
                reasons: self.partial_reasons.into_iter().collect(),
            }
        };
        let graph = AttachmentGraph {
            schema: GRAPH_SCHEMA.to_string(),
            job_id: self.job_id,
            root,
            root_name,
            objects: self.objects,
            edges: self.edges,
            issues: self.issues,
            coverage,
            limits: self.policy.limits,
            usage: self.budget.finish(),
        };
        let bundle = AttachmentBundle {
            graph,
            artifacts: Vec::new(),
            blobs: self.blobs,
        };
        bundle.validate().map_err(|error| AttachmentError {
            code: "inspection_contract_invalid".to_string(),
            class: IssueClass::Internal,
            safe_message: error.to_string(),
            object_id: None,
            retryable: false,
        })?;
        Ok(bundle)
    }

    fn expand_pdf(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        if let Err(error) = pdf_preflight::preflight(
            bytes,
            self.budget.remaining_objects(),
            self.budget.remaining_entries(),
            self.policy.limits.max_container_metadata_bytes,
        ) {
            let _ = self.set_status(
                parent,
                ObjectStatus::Partial {
                    reasons: vec![error.code.to_string()],
                },
            );
            self.issue(
                error.code,
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                error.message,
                true,
            );
            return;
        }
        let parser_stream_limit = usize::try_from(
            self.policy
                .limits
                .max_container_metadata_bytes
                .min(self.policy.limits.max_object_bytes),
        )
        .unwrap_or(usize::MAX);
        let document = match PdfDocument::load_mem_with_options(
            bytes,
            LoadOptions {
                strict: true,
                max_decompressed_size: Some(parser_stream_limit),
                ..LoadOptions::default()
            },
        ) {
            Ok(document) => document,
            Err(PdfError::Decompress(DecompressError::MemoryLimitExceeded { .. })) => {
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Partial {
                        reasons: vec!["pdf_parser_stream_limit_exceeded".to_string()],
                    },
                );
                self.issue(
                    "pdf_parser_stream_limit_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "A PDF object or cross-reference stream exceeded the configured bounded parser limit.",
                    true,
                );
                return;
            }
            Err(_) => {
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Malformed {
                        code: "pdf_structure_invalid".to_string(),
                    },
                );
                self.issue(
                    "pdf_structure_invalid",
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The attachment has PDF-like bytes but does not pass strict PDF structure parsing.",
                    true,
                );
                return;
            }
        };

        if document.is_encrypted() || document.was_encrypted() {
            let _ = self.set_status(
                parent,
                ObjectStatus::Unsupported {
                    code: "pdf_encrypted_unsupported".to_string(),
                },
            );
            self.issue(
                "pdf_encrypted_unsupported",
                IssueClass::Encrypted,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The PDF is encrypted. No password was requested and embedded content was not decrypted.",
                true,
            );
            return;
        }

        let scan = match pdf::scan_document(&document, MAX_PDF_STRUCTURE_NODES, || {
            self.budget.check_deadline()
        }) {
            Ok(scan) => scan,
            Err(pdf::ScanError::Deadline(error)) => {
                self.record_budget_issue(parent, &error);
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Partial {
                        reasons: vec![error.code],
                    },
                );
                return;
            }
            Err(pdf::ScanError::NodeLimit) => {
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Partial {
                        reasons: vec!["pdf_structure_scan_limit_exceeded".to_string()],
                    },
                );
                self.issue(
                    "pdf_structure_scan_limit_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The PDF structure exceeds the bounded passive-scan limit. No attacker-selected subset of embedded files was derived.",
                    true,
                );
                return;
            }
        };

        for active_content in scan.active_content {
            let (code, message) = active_content.issue();
            self.issue(
                code,
                IssueClass::Policy,
                IssueSeverity::Warning,
                Some(parent.clone()),
                message,
                false,
            );
        }

        if scan.embedded_files.is_empty() {
            return;
        }
        if !self.policy.inspect_pdf_embedded_files {
            let _ = self.set_status(
                parent,
                ObjectStatus::Partial {
                    reasons: vec!["pdf_embedded_file_inspection_disabled".to_string()],
                },
            );
            self.issue(
                "pdf_embedded_file_inspection_disabled",
                IssueClass::Policy,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The PDF declares embedded files, but the inspection policy disables their derivation.",
                true,
            );
            return;
        }

        let embedded_count = match u32::try_from(scan.embedded_files.len()) {
            Ok(count) => count,
            Err(_) => {
                self.mark_pdf_partial(parent, "pdf_embedded_file_count_overflow");
                self.issue(
                    "pdf_embedded_file_count_overflow",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The PDF embedded-file count cannot be represented safely.",
                    true,
                );
                return;
            }
        };
        if embedded_count > self.budget.remaining_entries() {
            self.mark_pdf_partial(parent, "archive_entry_limit_exceeded");
            self.issue(
                "archive_entry_limit_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                format!(
                    "The PDF declares {embedded_count} embedded files, exceeding the remaining global entry budget. No attacker-selected subset was derived."
                ),
                true,
            );
            return;
        }

        let mut partial = false;
        for (index, embedded) in scan.embedded_files.into_iter().enumerate() {
            match self.process_pdf_embedded_file(parent, depth, index, &document, embedded) {
                Ok(PdfChildOutcome::Complete) => {}
                Ok(PdfChildOutcome::PartialContinue) => partial = true,
                Ok(PdfChildOutcome::PartialStop) => {
                    partial = true;
                    break;
                }
                Err(error) => {
                    partial = true;
                    self.record_budget_issue(parent, &error);
                    break;
                }
            }
        }
        if partial {
            self.mark_pdf_partial(parent, "pdf_embedded_file_inspection_incomplete");
        }
    }

    fn process_pdf_embedded_file(
        &mut self,
        parent: &ObjectId,
        depth: u16,
        index: usize,
        document: &PdfDocument,
        embedded: pdf::EmbeddedFile,
    ) -> Result<PdfChildOutcome, AttachmentError> {
        let child_depth = depth.saturating_add(1);
        self.budget.charge_entry()?;
        let name = logical_member_name(
            &embedded.raw_name,
            index,
            self.policy.limits.max_name_bytes,
            self.policy.path_policy,
        )?;
        self.budget.charge_edge(child_depth)?;
        if let Some(reason) = name.reason {
            self.issue(
                reason,
                IssueClass::Policy,
                IssueSeverity::Warning,
                Some(parent.clone()),
                "A PDF embedded-file name was treated as inert metadata and sanitized.",
                !name.accepted,
            );
        }
        let mut edge = DerivationEdge {
            parent: parent.clone(),
            child: None,
            depth: child_depth,
            name: name.logical,
            transform: provenance(TransformKind::PdfEmbeddedFile),
            declared_uncompressed_bytes: None,
            compressed_bytes: None,
            source_range: None,
            outcome: EdgeOutcome::Malformed,
        };
        if !name.accepted {
            edge.outcome = EdgeOutcome::RejectedName;
            self.edges.push(edge);
            return Ok(PdfChildOutcome::PartialContinue);
        }
        if !self.budget.depth_allows_derivation(child_depth) {
            edge.outcome = EdgeOutcome::DepthExceeded;
            self.edges.push(edge);
            self.issue(
                "attachment_depth_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The PDF embedded file is visible in the graph but was not derived beyond the configured depth.",
                true,
            );
            return Ok(PdfChildOutcome::PartialContinue);
        }

        let Some(stream_id) = embedded.stream_id else {
            self.edges.push(edge);
            self.issue(
                "pdf_embedded_file_reference_invalid",
                IssueClass::Malformed,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "A PDF file specification does not resolve to an indirect embedded-file stream.",
                true,
            );
            return Ok(PdfChildOutcome::PartialContinue);
        };
        let stream = match document.get_object(stream_id) {
            Ok(PdfObject::Stream(stream)) => stream,
            _ => {
                self.edges.push(edge);
                self.issue(
                    "pdf_embedded_file_stream_invalid",
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "A PDF embedded-file reference does not resolve to a stream.",
                    true,
                );
                return Ok(PdfChildOutcome::PartialContinue);
            }
        };
        let compressed_bytes = u64::try_from(stream.content.len()).map_err(|_| {
            AttachmentError::budget(
                "derived_bytes_overflow",
                "A PDF embedded stream length cannot be represented safely.",
            )
        })?;
        let declared_size = pdf::declared_stream_size(document, stream);
        edge.compressed_bytes = Some(compressed_bytes);
        edge.declared_uncompressed_bytes = declared_size;
        if let Some(declared_size) = declared_size
            && let Err(error) = self
                .budget
                .check_declared_member(declared_size, Some(compressed_bytes))
        {
            edge.outcome = EdgeOutcome::BudgetExceeded;
            self.edges.push(edge);
            self.record_budget_issue(parent, &error);
            return Ok(PdfChildOutcome::PartialContinue);
        }

        let output_limit = self.budget.max_stream_output(Some(compressed_bytes));
        let output_limit = usize::try_from(output_limit).unwrap_or(usize::MAX);
        if output_limit == 0 {
            edge.outcome = EdgeOutcome::BudgetExceeded;
            self.edges.push(edge);
            self.issue(
                "derived_stream_limit_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "No global derived-byte budget remains for the PDF embedded stream.",
                true,
            );
            return Ok(PdfChildOutcome::PartialContinue);
        }

        let decoded = match stream.decompressed_content_with_limit(output_limit) {
            Ok(decoded) => decoded,
            Err(PdfError::Decompress(DecompressError::MemoryLimitExceeded { .. })) => {
                self.budget.charge_rejected_stream_attempt(
                    u64::try_from(output_limit).unwrap_or(u64::MAX),
                );
                edge.outcome = EdgeOutcome::BudgetExceeded;
                self.edges.push(edge);
                self.issue(
                    "derived_stream_limit_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "A PDF embedded stream exceeded its object, cumulative, or expansion-ratio limit.",
                    true,
                );
                // A limit failure proves the decoder produced at least the
                // allowed bound internally. Stop this PDF after the first such
                // attempt so repeated bombs cannot evade cumulative accounting
                // by failing before bytes reach the retained graph.
                return Ok(PdfChildOutcome::PartialStop);
            }
            Err(PdfError::Unimplemented(_)) => {
                edge.outcome = EdgeOutcome::UnsupportedCodec;
                self.edges.push(edge);
                self.issue(
                    "pdf_embedded_file_codec_unsupported",
                    IssueClass::Unsupported,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "A PDF embedded stream uses a compression filter unavailable in the safe core.",
                    true,
                );
                return Ok(PdfChildOutcome::PartialContinue);
            }
            Err(_) => {
                self.edges.push(edge);
                self.issue(
                    "pdf_embedded_file_decode_failed",
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "A PDF embedded stream failed bounded integrity or decompression checks.",
                    true,
                );
                return Ok(PdfChildOutcome::PartialContinue);
            }
        };
        self.budget.charge_derived_chunk(decoded.len())?;
        if declared_size.is_some_and(|declared| u64::try_from(decoded.len()).ok() != Some(declared))
        {
            self.edges.push(edge);
            self.issue(
                "pdf_embedded_file_size_mismatch",
                IssueClass::Integrity,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "A PDF embedded stream's decoded length does not match its declared length.",
                true,
            );
            return Ok(PdfChildOutcome::PartialContinue);
        }

        let declared_media_type = pdf::declared_stream_media_type(stream);
        if let Err(error) = self.finish_child(edge, decoded, declared_media_type.as_deref()) {
            self.record_budget_issue(parent, &error);
            return Ok(PdfChildOutcome::PartialStop);
        }
        Ok(PdfChildOutcome::Complete)
    }

    fn mark_pdf_partial(&mut self, parent: &ObjectId, reason: &str) {
        let _ = self.set_status(
            parent,
            ObjectStatus::Partial {
                reasons: vec![reason.to_string()],
            },
        );
    }

    fn expand_zip(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        let summary = match zip_preflight::preflight(bytes) {
            Ok(summary) => summary,
            Err(zip_preflight::ZipPreflightError::MultiDiskUnsupported) => {
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Unsupported {
                        code: "zip_multi_disk_unsupported".to_string(),
                    },
                );
                self.issue(
                    "zip_multi_disk_unsupported",
                    IssueClass::Unsupported,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "Multi-disk ZIP archives are not supported by the bounded in-process inspector.",
                    true,
                );
                return;
            }
            Err(_) => {
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Malformed {
                        code: "zip_structure_invalid".to_string(),
                    },
                );
                self.issue(
                    "zip_structure_invalid",
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The attachment has ZIP-like bytes but an invalid ZIP end record or directory boundary.",
                    true,
                );
                return;
            }
        };
        if summary.entries > u64::from(self.budget.remaining_entries()) {
            self.issue(
                "archive_entry_limit_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                format!(
                    "The ZIP declares {} entries, exceeding the remaining global entry budget. Its central directory was not materialized.",
                    summary.entries
                ),
                true,
            );
            let _ = self.set_status(
                parent,
                ObjectStatus::Partial {
                    reasons: vec!["archive_entry_limit_exceeded".to_string()],
                },
            );
            return;
        }
        if summary.metadata_bytes > self.policy.limits.max_container_metadata_bytes {
            self.issue(
                "container_metadata_limit_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                format!(
                    "The ZIP central directory declares {} bytes, exceeding the configured {} byte container-metadata limit. It was not materialized.",
                    summary.metadata_bytes, self.policy.limits.max_container_metadata_bytes
                ),
                true,
            );
            let _ = self.set_status(
                parent,
                ObjectStatus::Partial {
                    reasons: vec!["container_metadata_limit_exceeded".to_string()],
                },
            );
            return;
        }
        let cursor = Cursor::new(bytes);
        let mut archive = match zip::ZipArchive::new(cursor) {
            Ok(archive) => archive,
            Err(_) => {
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Malformed {
                        code: "zip_structure_invalid".to_string(),
                    },
                );
                self.issue(
                    "zip_structure_invalid",
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The attachment has ZIP-like bytes but an invalid ZIP structure.",
                    true,
                );
                return;
            }
        };
        let entry_count = match u32::try_from(archive.len()) {
            Ok(count) => count,
            Err(_) => {
                self.issue(
                    "zip_entry_count_overflow",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The ZIP entry count cannot be represented safely.",
                    true,
                );
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Partial {
                        reasons: vec!["zip_entry_count_overflow".to_string()],
                    },
                );
                return;
            }
        };
        if u64::from(entry_count) != summary.entries {
            self.issue(
                "zip_entry_count_mismatch",
                IssueClass::Integrity,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The ZIP parser entry count disagrees with the allocation preflight record.",
                true,
            );
            let _ = self.set_status(
                parent,
                ObjectStatus::Malformed {
                    code: "zip_entry_count_mismatch".to_string(),
                },
            );
            return;
        }
        if entry_count > self.budget.remaining_entries() {
            self.issue(
                "archive_entry_limit_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                format!(
                    "The ZIP contains {entry_count} entries, exceeding the remaining global entry budget. No attacker-selected subset was scanned."
                ),
                true,
            );
            let _ = self.set_status(
                parent,
                ObjectStatus::Partial {
                    reasons: vec!["archive_entry_limit_exceeded".to_string()],
                },
            );
            return;
        }

        let mut entries = Vec::with_capacity(archive.len());
        for index in 0..archive.len() {
            if let Err(error) = self.budget.charge_entry() {
                self.record_budget_issue(parent, &error);
                return;
            }
            let file = match archive.by_index_raw(index) {
                Ok(file) => file,
                Err(_) => {
                    self.issue(
                        "zip_entry_metadata_invalid",
                        IssueClass::Malformed,
                        IssueSeverity::Blocked,
                        Some(parent.clone()),
                        "A ZIP member has invalid metadata.",
                        true,
                    );
                    continue;
                }
            };
            entries.push(ZipEntryMetadata {
                index,
                raw_name: file.name_raw().to_vec(),
                display_name: file.name().to_string(),
                size: file.size(),
                compressed_size: file.compressed_size(),
                directory: file.is_dir(),
                symlink: file.is_symlink(),
                regular: file.is_file(),
                encrypted: file.encrypted(),
                unix_mode: file.unix_mode(),
                data_start: file.data_start(),
            });
        }
        entries.sort_by(|left, right| {
            left.raw_name
                .cmp(&right.raw_name)
                .then(left.index.cmp(&right.index))
        });

        let extension_hint = self
            .object(parent)
            .ok()
            .and_then(|object| object.detection.extension_hint.as_deref());
        let refined = classify_zip_members(
            entries.iter().map(|entry| entry.display_name.as_str()),
            extension_hint,
        );
        if let Err(error) = self.refine_zip_detection(parent, refined) {
            self.issue(
                "zip_detection_refinement_failed",
                IssueClass::Internal,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                error.safe_message,
                true,
            );
        }

        let mut container_partial = false;
        for metadata in entries {
            if let Err(error) = self.process_zip_entry(parent, depth, &mut archive, metadata) {
                container_partial = true;
                self.record_budget_issue(parent, &error);
                if !self.policy.continue_after_child_error {
                    break;
                }
            }
        }
        if container_partial {
            let _ = self.set_status(
                parent,
                ObjectStatus::Partial {
                    reasons: vec!["zip_child_processing_incomplete".to_string()],
                },
            );
        }
    }

    fn process_zip_entry(
        &mut self,
        parent: &ObjectId,
        depth: u16,
        archive: &mut zip::ZipArchive<Cursor<&[u8]>>,
        metadata: ZipEntryMetadata,
    ) -> Result<(), AttachmentError> {
        let child_depth = depth.saturating_add(1);
        let name = logical_member_name(
            &metadata.raw_name,
            metadata.index,
            self.policy.limits.max_name_bytes,
            self.policy.path_policy,
        )?;
        self.budget.charge_edge(child_depth)?;
        if let Some(reason) = name.reason {
            self.issue(
                reason,
                IssueClass::Policy,
                IssueSeverity::Warning,
                Some(parent.clone()),
                "An archive member name was treated as inert metadata and sanitized.",
                !name.accepted,
            );
        }
        let mut edge = DerivationEdge {
            parent: parent.clone(),
            child: None,
            depth: child_depth,
            name: name.logical,
            transform: provenance(TransformKind::ZipMember),
            declared_uncompressed_bytes: Some(metadata.size),
            compressed_bytes: Some(metadata.compressed_size),
            source_range: metadata
                .data_start
                .map(|start| attachment_native_types::ByteRange {
                    start,
                    end_exclusive: start.saturating_add(metadata.compressed_size),
                }),
            outcome: EdgeOutcome::Malformed,
        };
        if !name.accepted {
            edge.outcome = EdgeOutcome::RejectedName;
            self.edges.push(edge);
            return Ok(());
        }
        if metadata.directory {
            edge.outcome = EdgeOutcome::Directory;
            self.edges.push(edge);
            return Ok(());
        }
        if metadata.symlink || !metadata.regular || zip_mode_is_special(metadata.unix_mode) {
            edge.outcome = EdgeOutcome::SpecialFile;
            self.edges.push(edge);
            self.issue(
                "archive_special_file_skipped",
                IssueClass::Policy,
                IssueSeverity::Warning,
                Some(parent.clone()),
                "A ZIP symlink or special filesystem entry was not materialized or followed.",
                true,
            );
            return Ok(());
        }
        if metadata.encrypted {
            edge.outcome = EdgeOutcome::Encrypted;
            self.edges.push(edge);
            self.issue(
                "archive_member_encrypted",
                IssueClass::Encrypted,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "An encrypted ZIP member was not decrypted; coverage is incomplete.",
                true,
            );
            return Ok(());
        }
        if !self.budget.depth_allows_derivation(child_depth) {
            edge.outcome = EdgeOutcome::DepthExceeded;
            self.edges.push(edge);
            self.issue(
                "attachment_depth_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The member is visible in the graph but was not derived beyond the configured depth.",
                true,
            );
            return Ok(());
        }
        if let Err(error) = self
            .budget
            .check_declared_member(metadata.size, Some(metadata.compressed_size))
        {
            edge.outcome = EdgeOutcome::BudgetExceeded;
            self.edges.push(edge);
            self.record_budget_issue(parent, &error);
            return Ok(());
        }

        if self.budget.derived_budget_exhausted() {
            edge.outcome = EdgeOutcome::BudgetExceeded;
            self.edges.push(edge);
            self.issue(
                "total_derived_bytes_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The cumulative derived-byte budget is exhausted. This ZIP member's decoder was not opened.",
                true,
            );
            return Ok(());
        }

        let mut file = match archive.by_index(metadata.index) {
            Ok(file) => file,
            Err(_) => {
                edge.outcome = EdgeOutcome::UnsupportedCodec;
                self.edges.push(edge);
                self.issue(
                    "zip_codec_unsupported",
                    IssueClass::Unsupported,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "A ZIP member uses an unsupported or invalid compression method.",
                    true,
                );
                return Ok(());
            }
        };
        let bytes =
            match read_derived_bounded(&mut file, &mut self.budget, Some(metadata.compressed_size))
            {
                Ok(bytes) => bytes,
                Err(ReadFailure::Budget(error)) => {
                    edge.outcome = EdgeOutcome::BudgetExceeded;
                    self.edges.push(edge);
                    self.record_budget_issue(parent, &error);
                    return Ok(());
                }
                Err(ReadFailure::Io) => {
                    edge.outcome = EdgeOutcome::Malformed;
                    self.edges.push(edge);
                    self.issue(
                        "zip_member_decode_failed",
                        IssueClass::Malformed,
                        IssueSeverity::Blocked,
                        Some(parent.clone()),
                        "A ZIP member failed integrity or decompression checks.",
                        true,
                    );
                    return Ok(());
                }
            };
        if u64::try_from(bytes.len()).ok() != Some(metadata.size) {
            edge.outcome = EdgeOutcome::Malformed;
            self.edges.push(edge);
            self.issue(
                "zip_member_size_mismatch",
                IssueClass::Integrity,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "A ZIP member's decoded length does not match its declared length.",
                true,
            );
            return Ok(());
        }
        self.finish_child(edge, bytes, None)
    }

    fn expand_seven_zip(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        let limits = self.seven_zip_limits();
        let mut archive = match SeekArchiveReader::with_limits(Cursor::new(bytes), limits) {
            Ok(archive) => archive,
            Err(error) => {
                self.record_seven_zip_open_error(parent, &error);
                return;
            }
        };
        let mut pending: Option<SevenZipPending> = None;
        let mut partial = false;

        loop {
            if let Err(error) = self.budget.check_deadline() {
                self.record_budget_issue(parent, &error);
                partial = true;
                break;
            }
            let event = match archive.next_event() {
                Ok(event) => event,
                Err(error) => {
                    self.record_seven_zip_stream_error(parent, pending.take(), &error);
                    partial = true;
                    break;
                }
            };
            match event {
                ReaderEvent::ArchiveMetadata(_) => {}
                ReaderEvent::Entry(metadata) => {
                    if pending.is_some() {
                        self.issue(
                            "seven_zip_event_protocol_invalid",
                            IssueClass::Internal,
                            IssueSeverity::Blocked,
                            Some(parent.clone()),
                            "The 7z decoder began a member before ending the previous member.",
                            true,
                        );
                        partial = true;
                        break;
                    }
                    match self.begin_seven_zip_entry(parent, depth, metadata) {
                        Ok(next) => pending = Some(next),
                        Err(error) => {
                            self.record_budget_issue(parent, &error);
                            partial = true;
                            break;
                        }
                    }
                }
                ReaderEvent::Data(chunk) => {
                    let Some(current) = pending.as_mut() else {
                        self.issue(
                            "seven_zip_event_protocol_invalid",
                            IssueClass::Internal,
                            IssueSeverity::Blocked,
                            Some(parent.clone()),
                            "The 7z decoder emitted member bytes without an open member.",
                            true,
                        );
                        partial = true;
                        break;
                    };
                    if let Err(error) = self.budget.charge_derived_chunk(chunk.len()) {
                        current.edge.outcome = EdgeOutcome::BudgetExceeded;
                        let failed = pending.take().map(|entry| entry.edge);
                        if let Some(edge) = failed {
                            self.edges.push(edge);
                        }
                        self.record_budget_issue(parent, &error);
                        partial = true;
                        break;
                    }
                    if current.retain {
                        if current.bytes.try_reserve(chunk.len()).is_err() {
                            current.edge.outcome = EdgeOutcome::BudgetExceeded;
                            let failed = pending.take().map(|entry| entry.edge);
                            if let Some(edge) = failed {
                                self.edges.push(edge);
                            }
                            self.issue(
                                "seven_zip_member_allocation_failed",
                                IssueClass::Budget,
                                IssueSeverity::Blocked,
                                Some(parent.clone()),
                                "A decoded 7z member could not be retained within available memory.",
                                true,
                            );
                            partial = true;
                            break;
                        }
                        current.bytes.extend_from_slice(chunk);
                    }
                }
                ReaderEvent::EndEntry => {
                    let Some(current) = pending.take() else {
                        self.issue(
                            "seven_zip_event_protocol_invalid",
                            IssueClass::Internal,
                            IssueSeverity::Blocked,
                            Some(parent.clone()),
                            "The 7z decoder ended a member that was not open.",
                            true,
                        );
                        partial = true;
                        break;
                    };
                    if !self.finish_seven_zip_entry(parent, current) {
                        partial = true;
                        if !self.policy.continue_after_child_error {
                            break;
                        }
                    }
                }
                ReaderEvent::Done => {
                    if let Some(mut current) = pending.take() {
                        current.edge.outcome = EdgeOutcome::Malformed;
                        self.edges.push(current.edge);
                        self.issue(
                            "seven_zip_member_truncated",
                            IssueClass::Malformed,
                            IssueSeverity::Blocked,
                            Some(parent.clone()),
                            "The 7z archive ended before its current member ended.",
                            true,
                        );
                        partial = true;
                    }
                    break;
                }
                _ => {
                    self.issue(
                        "seven_zip_event_unsupported",
                        IssueClass::Unsupported,
                        IssueSeverity::Blocked,
                        Some(parent.clone()),
                        "The 7z decoder emitted an event this inspector does not support.",
                        true,
                    );
                    partial = true;
                    break;
                }
            }
        }

        if partial {
            let _ = self.set_status(
                parent,
                ObjectStatus::Partial {
                    reasons: vec!["seven_zip_inspection_incomplete".to_string()],
                },
            );
        }
    }

    fn seven_zip_limits(&self) -> Limits {
        let entries = self
            .budget
            .remaining_entries()
            .min(self.budget.remaining_edges());
        let metadata = saturating_usize(self.policy.limits.max_container_metadata_bytes);
        let codec_memory = saturating_usize(
            self.policy
                .limits
                .max_container_metadata_bytes
                .min(self.policy.limits.max_parser_input_bytes)
                .min(self.policy.limits.max_decoder_window_bytes),
        );
        let in_flight = saturating_usize(self.policy.limits.max_object_bytes.min(64 * 1024));
        Limits::safe()
            .with_decoded_total(Some(self.budget.remaining_derived_bytes()))
            .with_entry_bytes(Some(self.policy.limits.max_object_bytes))
            .with_entries(Some(u64::from(entries)))
            .with_metadata_bytes(Some(metadata))
            .with_codec_memory(Some(codec_memory))
            .with_path_bytes(Some(
                usize::try_from(self.policy.limits.max_name_bytes).unwrap_or(usize::MAX),
            ))
            .with_nesting(Some(usize::from(
                self.policy.limits.max_depth.saturating_add(1),
            )))
            .with_filter_depth(Some(1))
            .with_in_flight_bytes(Some(in_flight))
    }

    fn begin_seven_zip_entry(
        &mut self,
        parent: &ObjectId,
        depth: u16,
        metadata: libarchive_oxide::libarchive_oxide_core::EntryMetadata,
    ) -> Result<SevenZipPending, AttachmentError> {
        self.budget.charge_entry()?;
        let child_depth = depth.saturating_add(1);
        let index = usize::try_from(self.budget_entry_index()).unwrap_or(usize::MAX);
        let name = logical_member_name(
            metadata.path().as_bytes(),
            index,
            self.policy.limits.max_name_bytes,
            self.policy.path_policy,
        )?;
        let declared = metadata.size();
        if metadata.kind() == EntryKind::Symlink
            && metadata.link_target().is_some()
            && let Some(bytes) = declared
        {
            let bytes = usize::try_from(bytes).map_err(|_| {
                AttachmentError::budget(
                    "derived_bytes_overflow",
                    "A decoded 7z link-target length cannot be represented safely.",
                )
            })?;
            self.budget.charge_derived_chunk(bytes)?;
        }
        self.budget.charge_edge(child_depth)?;
        if let Some(reason) = name.reason {
            self.issue(
                reason,
                IssueClass::Policy,
                IssueSeverity::Warning,
                Some(parent.clone()),
                "A 7z member name was treated as inert metadata and sanitized.",
                !name.accepted,
            );
        }
        let mut edge = DerivationEdge {
            parent: parent.clone(),
            child: None,
            depth: child_depth,
            name: name.logical,
            transform: provenance(TransformKind::SevenZipMember),
            declared_uncompressed_bytes: declared,
            compressed_bytes: None,
            source_range: None,
            outcome: EdgeOutcome::Malformed,
        };
        let retain = if !name.accepted {
            edge.outcome = EdgeOutcome::RejectedName;
            false
        } else if metadata.kind() == EntryKind::Dir {
            edge.outcome = EdgeOutcome::Directory;
            false
        } else if metadata.is_encrypted() {
            edge.outcome = EdgeOutcome::Encrypted;
            self.issue(
                "seven_zip_member_encrypted",
                IssueClass::Encrypted,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "An encrypted 7z member was not decrypted; coverage is incomplete.",
                true,
            );
            false
        } else if metadata.kind() != EntryKind::File {
            edge.outcome = EdgeOutcome::SpecialFile;
            self.issue(
                "archive_special_file_skipped",
                IssueClass::Policy,
                IssueSeverity::Warning,
                Some(parent.clone()),
                "A 7z link or special filesystem entry was retained only as inert metadata.",
                true,
            );
            false
        } else if !self.budget.depth_allows_derivation(child_depth) {
            edge.outcome = EdgeOutcome::DepthExceeded;
            self.issue(
                "attachment_depth_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The 7z member is visible in the graph but was not retained beyond the configured depth.",
                true,
            );
            false
        } else if let Some(declared) = declared {
            if let Err(error) = self.budget.check_declared_member(declared, None) {
                edge.outcome = EdgeOutcome::BudgetExceeded;
                self.record_budget_issue(parent, &error);
                false
            } else {
                true
            }
        } else {
            true
        };

        Ok(SevenZipPending {
            edge,
            declared,
            retain,
            bytes: Vec::new(),
        })
    }

    fn finish_seven_zip_entry(&mut self, parent: &ObjectId, mut current: SevenZipPending) -> bool {
        if !current.retain {
            self.edges.push(current.edge);
            return true;
        }
        if let Some(declared) = current.declared
            && u64::try_from(current.bytes.len()).ok() != Some(declared)
        {
            current.edge.outcome = EdgeOutcome::Malformed;
            self.edges.push(current.edge);
            self.issue(
                "seven_zip_member_size_mismatch",
                IssueClass::Integrity,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "A 7z member's decoded length does not match its declared length.",
                true,
            );
            return false;
        }
        if let Err(error) = self.finish_child(current.edge, current.bytes, None) {
            self.record_budget_issue(parent, &error);
            return false;
        }
        true
    }

    fn record_seven_zip_open_error(&mut self, parent: &ObjectId, error: &StreamError) {
        let kind = error
            .archive_error()
            .map(|error| error.kind())
            .unwrap_or(ErrorKind::Malformed);
        let (code, class, status, message) = match kind {
            ErrorKind::Limit => (
                "seven_zip_native_limit_exceeded",
                IssueClass::Budget,
                ObjectStatus::Partial {
                    reasons: vec!["seven_zip_native_limit_exceeded".to_string()],
                },
                "The 7z archive exceeds an entry, decoded-byte, member, metadata, codec-memory, path, nesting, filter-depth, or in-flight safety limit.",
            ),
            ErrorKind::Unsupported | ErrorKind::Capability => (
                "seven_zip_layout_unsupported",
                IssueClass::Unsupported,
                ObjectStatus::Unsupported {
                    code: "seven_zip_layout_unsupported".to_string(),
                },
                "The 7z archive uses encryption, a coder, or a layout outside the audited in-process subset.",
            ),
            ErrorKind::Malformed | ErrorKind::Integrity => (
                "seven_zip_structure_invalid",
                IssueClass::Malformed,
                ObjectStatus::Malformed {
                    code: "seven_zip_structure_invalid".to_string(),
                },
                "The attachment has 7z-like bytes but failed structural or integrity validation.",
            ),
            _ => (
                "seven_zip_decoder_failed",
                IssueClass::Internal,
                ObjectStatus::Partial {
                    reasons: vec!["seven_zip_decoder_failed".to_string()],
                },
                "The bounded 7z decoder could not establish complete coverage.",
            ),
        };
        let _ = self.set_status(parent, status);
        self.issue(
            code,
            class,
            IssueSeverity::Blocked,
            Some(parent.clone()),
            message,
            true,
        );
    }

    fn record_seven_zip_stream_error(
        &mut self,
        parent: &ObjectId,
        pending: Option<SevenZipPending>,
        error: &StreamError,
    ) {
        let kind = error
            .archive_error()
            .map(|error| error.kind())
            .unwrap_or(ErrorKind::Malformed);
        let (outcome, code, class, message) = match kind {
            ErrorKind::Limit => (
                EdgeOutcome::BudgetExceeded,
                "seven_zip_native_limit_exceeded",
                IssueClass::Budget,
                "A 7z member exceeded a native decoder safety limit.",
            ),
            ErrorKind::Unsupported | ErrorKind::Capability => (
                EdgeOutcome::UnsupportedCodec,
                "seven_zip_codec_unsupported",
                IssueClass::Unsupported,
                "A 7z member uses encryption, a coder, or a layout outside the audited in-process subset.",
            ),
            ErrorKind::Malformed | ErrorKind::Integrity => (
                EdgeOutcome::Malformed,
                "seven_zip_member_decode_failed",
                IssueClass::Malformed,
                "A 7z member failed structural, integrity, or decompression validation.",
            ),
            _ => (
                EdgeOutcome::Malformed,
                "seven_zip_decoder_failed",
                IssueClass::Internal,
                "The bounded 7z decoder could not establish complete coverage.",
            ),
        };
        if let Some(mut pending) = pending {
            pending.edge.outcome = outcome;
            self.edges.push(pending.edge);
        }
        self.issue(
            code,
            class,
            IssueSeverity::Blocked,
            Some(parent.clone()),
            message,
            true,
        );
    }

    fn budget_entry_index(&self) -> u32 {
        self.policy
            .limits
            .max_entries
            .saturating_sub(self.budget.remaining_entries())
            .saturating_sub(1)
    }

    fn expand_tar(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        let mut archive = tar::Archive::new(Cursor::new(bytes));
        let entries = match archive.entries() {
            Ok(entries) => entries,
            Err(_) => {
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Malformed {
                        code: "tar_structure_invalid".to_string(),
                    },
                );
                self.issue(
                    "tar_structure_invalid",
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The attachment has TAR-like bytes but an invalid TAR structure.",
                    true,
                );
                return;
            }
        };
        let mut container_partial = false;
        for (index, entry) in entries.enumerate() {
            if let Err(error) = self.budget.charge_entry() {
                self.record_budget_issue(parent, &error);
                container_partial = true;
                break;
            }
            let mut entry = match entry {
                Ok(entry) => entry,
                Err(_) => {
                    self.issue(
                        "tar_entry_metadata_invalid",
                        IssueClass::Malformed,
                        IssueSeverity::Blocked,
                        Some(parent.clone()),
                        "A TAR member has invalid metadata.",
                        true,
                    );
                    container_partial = true;
                    break;
                }
            };
            if let Err(error) = self.process_tar_entry(parent, depth, index, &mut entry) {
                self.record_budget_issue(parent, &error);
                container_partial = true;
                if !self.policy.continue_after_child_error {
                    break;
                }
            }
        }
        if container_partial {
            let _ = self.set_status(
                parent,
                ObjectStatus::Partial {
                    reasons: vec!["tar_child_processing_incomplete".to_string()],
                },
            );
        }
    }

    fn process_tar_entry<R: Read>(
        &mut self,
        parent: &ObjectId,
        depth: u16,
        index: usize,
        entry: &mut tar::Entry<'_, R>,
    ) -> Result<(), AttachmentError> {
        let child_depth = depth.saturating_add(1);
        let raw_name = entry.path_bytes();
        self.budget.check_name_len(raw_name.len())?;
        let name = logical_member_name(
            raw_name.as_ref(),
            index,
            self.policy.limits.max_name_bytes,
            self.policy.path_policy,
        )?;
        self.budget.charge_edge(child_depth)?;
        let size = entry.size();
        let mut edge = DerivationEdge {
            parent: parent.clone(),
            child: None,
            depth: child_depth,
            name: name.logical,
            transform: provenance(TransformKind::TarMember),
            declared_uncompressed_bytes: Some(size),
            compressed_bytes: Some(size),
            source_range: None,
            outcome: EdgeOutcome::Malformed,
        };
        if let Some(reason) = name.reason {
            self.issue(
                reason,
                IssueClass::Policy,
                IssueSeverity::Warning,
                Some(parent.clone()),
                "An archive member name was treated as inert metadata and sanitized.",
                !name.accepted,
            );
        }
        if !name.accepted {
            edge.outcome = EdgeOutcome::RejectedName;
            self.edges.push(edge);
            return Ok(());
        }
        let entry_type = entry.header().entry_type();
        if entry_type.is_dir() {
            edge.outcome = EdgeOutcome::Directory;
            self.edges.push(edge);
            return Ok(());
        }
        if !entry_type.is_file() {
            edge.outcome = EdgeOutcome::SpecialFile;
            self.edges.push(edge);
            self.issue(
                "archive_special_file_skipped",
                IssueClass::Policy,
                IssueSeverity::Warning,
                Some(parent.clone()),
                "A TAR link, sparse object, device, pipe, or other special entry was not materialized or followed.",
                true,
            );
            return Ok(());
        }
        if !self.budget.depth_allows_derivation(child_depth) {
            edge.outcome = EdgeOutcome::DepthExceeded;
            self.edges.push(edge);
            self.issue(
                "attachment_depth_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The member is visible in the graph but was not derived beyond the configured depth.",
                true,
            );
            return Ok(());
        }
        if let Err(error) = self.budget.check_declared_member(size, None) {
            edge.outcome = EdgeOutcome::BudgetExceeded;
            self.edges.push(edge);
            self.record_budget_issue(parent, &error);
            return Ok(());
        }
        let bytes = match read_derived_bounded(entry, &mut self.budget, None) {
            Ok(bytes) => bytes,
            Err(ReadFailure::Budget(error)) => {
                edge.outcome = EdgeOutcome::BudgetExceeded;
                self.edges.push(edge);
                self.record_budget_issue(parent, &error);
                return Ok(());
            }
            Err(ReadFailure::Io) => {
                edge.outcome = EdgeOutcome::Malformed;
                self.edges.push(edge);
                self.issue(
                    "tar_member_decode_failed",
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "A TAR member could not be read completely.",
                    true,
                );
                return Ok(());
            }
        };
        if u64::try_from(bytes.len()).ok() != Some(size) {
            edge.outcome = EdgeOutcome::Malformed;
            self.edges.push(edge);
            self.issue(
                "tar_member_size_mismatch",
                IssueClass::Integrity,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "A TAR member's decoded length does not match its declared length.",
                true,
            );
            return Ok(());
        }
        self.finish_child(edge, bytes, None)
    }

    fn expand_gzip(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        let mut decoder = GzDecoder::new(Cursor::new(bytes));
        let raw_name = decoder
            .header()
            .and_then(|header| header.filename())
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| b"gzip-payload".to_vec());
        self.expand_compressed_stream(
            parent,
            depth,
            CompressedStreamSpec {
                compressed_source_len: bytes.len(),
                raw_name: &raw_name,
                transform: TransformKind::GzipPayload,
                decode_error_code: "gzip_decode_failed",
                decode_error_message: "The GZIP payload failed integrity or decompression checks.",
            },
            &mut decoder,
        );
    }

    fn expand_bzip2(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        let mut decoder = crabz2::reader(Cursor::new(bytes));
        self.expand_compressed_stream(
            parent,
            depth,
            CompressedStreamSpec {
                compressed_source_len: bytes.len(),
                raw_name: b"bzip2-payload",
                transform: TransformKind::Bzip2Payload,
                decode_error_code: "bzip2_decode_failed",
                decode_error_message: "The BZIP2 payload failed integrity or decompression checks.",
            },
            &mut decoder,
        );
    }

    fn expand_xz(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        let _summary = match xz_preflight::preflight_xz(
            bytes,
            // Each index record needs at least two VLI bytes. Derive the work
            // bound from metadata bytes, not the graph-entry budget: an XZ
            // block is not a separately exposed attachment.
            self.policy
                .limits
                .max_container_metadata_bytes
                .saturating_div(2),
            self.policy.limits.max_container_metadata_bytes,
            self.policy.limits.max_decoder_window_bytes,
        ) {
            Ok(summary) => summary,
            Err(error) => {
                let (class, status) = match error.class {
                    xz_preflight::XzPreflightClass::Malformed => (
                        IssueClass::Malformed,
                        ObjectStatus::Malformed {
                            code: error.code.to_string(),
                        },
                    ),
                    xz_preflight::XzPreflightClass::Unsupported => (
                        IssueClass::Unsupported,
                        ObjectStatus::Unsupported {
                            code: error.code.to_string(),
                        },
                    ),
                    xz_preflight::XzPreflightClass::Limit => (
                        IssueClass::Budget,
                        ObjectStatus::Partial {
                            reasons: vec![error.code.to_string()],
                        },
                    ),
                };
                let _ = self.set_status(parent, status);
                self.issue(
                    error.code,
                    class,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    error.message,
                    true,
                );
                return;
            }
        };
        // XZ blocks bound preflight work; they are not separate derived graph
        // entries. `expand_compressed_stream` charges the single payload once.
        let mut decoder = lzma_rust2::XzReader::new(Cursor::new(bytes), false);
        self.expand_compressed_stream(
            parent,
            depth,
            CompressedStreamSpec {
                compressed_source_len: bytes.len(),
                raw_name: b"xz-payload",
                transform: TransformKind::XzPayload,
                decode_error_code: "xz_decode_failed",
                decode_error_message: "The XZ payload failed integrity or decompression checks.",
            },
            &mut decoder,
        );
    }

    fn expand_zstd(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        let decoder = ruzstd::decoding::StreamingDecoder::new_with_max_window_size(
            Cursor::new(bytes),
            self.policy.limits.max_decoder_window_bytes,
        );
        let mut decoder = match decoder {
            Ok(decoder) => decoder,
            Err(error) => {
                if matches!(
                    error,
                    ruzstd::decoding::errors::FrameDecoderError::WindowSizeTooBig { .. }
                ) {
                    let _ = self.set_status(
                        parent,
                        ObjectStatus::Partial {
                            reasons: vec!["zstd_window_limit_exceeded".to_string()],
                        },
                    );
                    self.issue(
                    "zstd_window_limit_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The Zstandard frame requests a decoder window larger than the configured memory limit.",
                    true,
                );
                    return;
                }
                let _ = self.set_status(
                    parent,
                    ObjectStatus::Malformed {
                        code: "zstd_structure_invalid".to_string(),
                    },
                );
                self.issue(
                    "zstd_structure_invalid",
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The attachment has Zstandard-like bytes but an invalid frame header.",
                    true,
                );
                return;
            }
        };
        self.expand_compressed_stream(
            parent,
            depth,
            CompressedStreamSpec {
                compressed_source_len: bytes.len(),
                raw_name: b"zstd-payload",
                transform: TransformKind::ZstdPayload,
                decode_error_code: "zstd_decode_failed",
                decode_error_message:
                    "The Zstandard payload failed integrity or decompression checks.",
            },
            &mut decoder,
        );
    }

    fn expand_compressed_stream(
        &mut self,
        parent: &ObjectId,
        depth: u16,
        spec: CompressedStreamSpec<'_>,
        decoder: &mut impl Read,
    ) {
        let child_depth = depth.saturating_add(1);
        if let Err(error) = self.budget.charge_entry() {
            self.record_budget_issue(parent, &error);
            return;
        }
        let name = match logical_member_name(
            spec.raw_name,
            0,
            self.policy.limits.max_name_bytes,
            self.policy.path_policy,
        ) {
            Ok(name) => name,
            Err(error) => {
                self.record_budget_issue(parent, &error);
                return;
            }
        };
        if let Err(error) = self.budget.charge_edge(child_depth) {
            self.record_budget_issue(parent, &error);
            return;
        }
        let mut edge = DerivationEdge {
            parent: parent.clone(),
            child: None,
            depth: child_depth,
            name: name.logical,
            transform: provenance(spec.transform),
            declared_uncompressed_bytes: None,
            compressed_bytes: u64::try_from(spec.compressed_source_len).ok(),
            source_range: None,
            outcome: EdgeOutcome::Malformed,
        };
        if !name.accepted {
            edge.outcome = EdgeOutcome::RejectedName;
            self.edges.push(edge);
            self.issue(
                name.reason.unwrap_or("compressed_payload_name_rejected"),
                IssueClass::Policy,
                IssueSeverity::Warning,
                Some(parent.clone()),
                "The compressed payload name was rejected as unsafe metadata.",
                true,
            );
            return;
        }
        if !self.budget.depth_allows_derivation(child_depth) {
            edge.outcome = EdgeOutcome::DepthExceeded;
            self.edges.push(edge);
            self.issue(
                "attachment_depth_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The compressed payload was not derived beyond the configured depth.",
                true,
            );
            return;
        }
        let compressed = u64::try_from(spec.compressed_source_len).ok();
        let decoded = match read_derived_bounded(decoder, &mut self.budget, compressed) {
            Ok(decoded) => decoded,
            Err(ReadFailure::Budget(error)) => {
                edge.outcome = EdgeOutcome::BudgetExceeded;
                self.edges.push(edge);
                self.record_budget_issue(parent, &error);
                return;
            }
            Err(ReadFailure::Io) => {
                edge.outcome = EdgeOutcome::Malformed;
                self.edges.push(edge);
                self.issue(
                    spec.decode_error_code,
                    IssueClass::Malformed,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    spec.decode_error_message,
                    true,
                );
                return;
            }
        };
        if let Err(error) = self.finish_child(edge, decoded, None) {
            self.record_budget_issue(parent, &error);
        }
    }

    fn expand_email(&mut self, parent: &ObjectId, depth: u16, bytes: &[u8]) {
        let max_parts = self
            .budget
            .remaining_entries()
            .min(self.budget.remaining_edges())
            .min(self.budget.remaining_objects());
        if let Err(error) = mime_preflight::preflight(
            bytes,
            max_parts,
            self.policy.limits.max_container_metadata_bytes,
            self.budget.remaining_derived_bytes(),
        ) {
            let _ = self.set_status(
                parent,
                ObjectStatus::Partial {
                    reasons: vec![error.code.to_string()],
                },
            );
            self.issue(
                error.code,
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                error.message,
                true,
            );
            return;
        }
        let Some(message) = MessageParser::default().parse(bytes) else {
            let _ = self.set_status(
                parent,
                ObjectStatus::Malformed {
                    code: "email_structure_invalid".to_string(),
                },
            );
            self.issue(
                "email_structure_invalid",
                IssueClass::Malformed,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The attachment resembles an email but its MIME structure is invalid.",
                true,
            );
            return;
        };
        let count = match u32::try_from(message.attachment_count()) {
            Ok(count) => count,
            Err(_) => {
                self.issue(
                    "email_part_count_overflow",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The email attachment count cannot be represented safely.",
                    true,
                );
                return;
            }
        };
        if count > self.budget.remaining_entries() {
            self.issue(
                "archive_entry_limit_exceeded",
                IssueClass::Budget,
                IssueSeverity::Blocked,
                Some(parent.clone()),
                "The email contains more MIME attachments than the remaining global entry budget; no attacker-selected subset was scanned.",
                true,
            );
            return;
        }
        for (index, part) in message.attachments().enumerate() {
            if let Err(error) = self.budget.charge_entry() {
                self.record_budget_issue(parent, &error);
                break;
            }
            let child_depth = depth.saturating_add(1);
            let fallback = format!("email-part-{index}");
            let raw_name = part.attachment_name().unwrap_or(&fallback).as_bytes();
            let name = match logical_member_name(
                raw_name,
                index,
                self.policy.limits.max_name_bytes,
                self.policy.path_policy,
            ) {
                Ok(name) => name,
                Err(error) => {
                    self.record_budget_issue(parent, &error);
                    continue;
                }
            };
            let part_bytes = part.contents();
            let declared = match u64::try_from(part_bytes.len()) {
                Ok(value) => value,
                Err(_) => {
                    self.issue(
                        "email_part_size_overflow",
                        IssueClass::Budget,
                        IssueSeverity::Blocked,
                        Some(parent.clone()),
                        "An email MIME part length cannot be represented safely.",
                        true,
                    );
                    continue;
                }
            };
            if let Err(error) = self.budget.charge_edge(child_depth) {
                self.record_budget_issue(parent, &error);
                break;
            }
            let mut edge = DerivationEdge {
                parent: parent.clone(),
                child: None,
                depth: child_depth,
                name: name.logical,
                transform: provenance(TransformKind::EmailPart),
                declared_uncompressed_bytes: Some(declared),
                compressed_bytes: None,
                source_range: None,
                outcome: EdgeOutcome::Malformed,
            };
            if !name.accepted {
                edge.outcome = EdgeOutcome::RejectedName;
                self.edges.push(edge);
                self.issue(
                    name.reason.unwrap_or("email_part_name_rejected"),
                    IssueClass::Policy,
                    IssueSeverity::Warning,
                    Some(parent.clone()),
                    "An email MIME part name was rejected as unsafe metadata.",
                    true,
                );
                continue;
            }
            if !self.budget.depth_allows_derivation(child_depth) {
                edge.outcome = EdgeOutcome::DepthExceeded;
                self.edges.push(edge);
                self.issue(
                    "attachment_depth_exceeded",
                    IssueClass::Budget,
                    IssueSeverity::Blocked,
                    Some(parent.clone()),
                    "The email MIME part was not derived beyond the configured depth.",
                    true,
                );
                continue;
            }
            if let Err(error) = self.budget.check_declared_member(declared, None) {
                edge.outcome = EdgeOutcome::BudgetExceeded;
                self.edges.push(edge);
                self.record_budget_issue(parent, &error);
                continue;
            }
            if let Err(error) = self.budget.charge_derived_chunk(part_bytes.len()) {
                edge.outcome = EdgeOutcome::BudgetExceeded;
                self.edges.push(edge);
                self.record_budget_issue(parent, &error);
                continue;
            }
            let media_type = part.content_type().map(|content_type| {
                content_type.subtype().map_or_else(
                    || content_type.ctype().to_string(),
                    |subtype| format!("{}/{}", content_type.ctype(), subtype),
                )
            });
            if let Err(error) = self.finish_child(edge, part_bytes.to_vec(), media_type.as_deref())
            {
                self.record_budget_issue(parent, &error);
            }
        }
    }

    fn finish_child(
        &mut self,
        mut edge: DerivationEdge,
        bytes: Vec<u8>,
        declared_media_type: Option<&str>,
    ) -> Result<(), AttachmentError> {
        let byte_len = match u64::try_from(bytes.len()) {
            Ok(byte_len) => byte_len,
            Err(_) => {
                edge.outcome = EdgeOutcome::BudgetExceeded;
                self.edges.push(edge);
                return Err(AttachmentError::budget(
                    "derived_bytes_overflow",
                    "A derived object length cannot be represented safely.",
                ));
            }
        };
        let digest = sha256(&bytes);
        let id = ObjectId(digest.clone());
        if self.object_index.contains_key(&id) {
            edge.child = Some(id.clone());
            edge.outcome = EdgeOutcome::Duplicate;
            self.edges.push(edge);
            return Ok(());
        }
        if let Err(error) = self.budget.charge_unique_object(byte_len, edge.depth) {
            edge.child = None;
            edge.outcome = EdgeOutcome::BudgetExceeded;
            self.edges.push(edge);
            return Err(error);
        }
        edge.child = Some(id.clone());
        let name = edge.name.display.clone();
        let detection = detect(&name, declared_media_type, &bytes);
        if let Some(mismatch) = &detection.mismatch {
            self.issue(
                "archive_member_type_mismatch",
                IssueClass::Detection,
                IssueSeverity::Warning,
                Some(id.clone()),
                format!(
                    "An archive member name suggests {}, but its bytes indicate {}.",
                    mismatch.hint, mismatch.detected
                ),
                false,
            );
        }
        let index = self.objects.len();
        self.object_index.insert(id.clone(), index);
        self.objects.push(ObjectRecord {
            id: id.clone(),
            sha256: digest,
            byte_len,
            detection,
            status: ObjectStatus::Complete,
            first_depth: edge.depth,
            artifact_ids: Vec::new(),
        });
        self.blobs.insert(id.clone(), Arc::from(bytes));
        self.queue.push_back((id, edge.depth));
        edge.outcome = EdgeOutcome::Derived;
        self.edges.push(edge);
        Ok(())
    }

    fn mark_unsupported_container(&mut self, object_id: &ObjectId, format: Option<DetectedFormat>) {
        let label = format
            .map(|format| format.canonical_media_type())
            .unwrap_or("unknown container");
        let _ = self.set_status(
            object_id,
            ObjectStatus::Unsupported {
                code: "container_decoder_unavailable".to_string(),
            },
        );
        self.issue(
            "container_decoder_unavailable",
            IssueClass::Unsupported,
            IssueSeverity::Blocked,
            Some(object_id.clone()),
            format!(
                "The {label} container was detected, but its audited decoder is not enabled in the safe core."
            ),
            true,
        );
    }

    fn refine_zip_detection(
        &mut self,
        object_id: &ObjectId,
        format: DetectedFormat,
    ) -> Result<(), AttachmentError> {
        let object = self.object_mut(object_id)?;
        object.detection.selected = Some(format);
        if !object.detection.candidates.iter().any(|candidate| {
            candidate.format == format
                && candidate.confidence == DetectionConfidence::ParserConfirmed
        }) {
            object.detection.candidates.insert(
                0,
                FormatCandidate {
                    format,
                    confidence: DetectionConfidence::ParserConfirmed,
                    evidence: DetectionEvidence::ContainerMembers,
                    offset: 0,
                },
            );
        }
        Ok(())
    }

    fn object(&self, object_id: &ObjectId) -> Result<&ObjectRecord, AttachmentError> {
        let index = self
            .object_index
            .get(object_id)
            .ok_or_else(|| AttachmentError {
                code: "object_index_missing".to_string(),
                class: IssueClass::Internal,
                safe_message: "An inspected object is absent from its index.".to_string(),
                object_id: Some(object_id.clone()),
                retryable: false,
            })?;
        self.objects.get(*index).ok_or_else(|| AttachmentError {
            code: "object_record_missing".to_string(),
            class: IssueClass::Internal,
            safe_message: "An inspected object record is absent.".to_string(),
            object_id: Some(object_id.clone()),
            retryable: false,
        })
    }

    fn object_mut(&mut self, object_id: &ObjectId) -> Result<&mut ObjectRecord, AttachmentError> {
        let index = self
            .object_index
            .get(object_id)
            .copied()
            .ok_or_else(|| AttachmentError {
                code: "object_index_missing".to_string(),
                class: IssueClass::Internal,
                safe_message: "An inspected object is absent from its index.".to_string(),
                object_id: Some(object_id.clone()),
                retryable: false,
            })?;
        self.objects.get_mut(index).ok_or_else(|| AttachmentError {
            code: "object_record_missing".to_string(),
            class: IssueClass::Internal,
            safe_message: "An inspected object record is absent.".to_string(),
            object_id: Some(object_id.clone()),
            retryable: false,
        })
    }

    fn set_status(
        &mut self,
        object_id: &ObjectId,
        status: ObjectStatus,
    ) -> Result<(), AttachmentError> {
        self.object_mut(object_id)?.status = status;
        Ok(())
    }

    fn issue(
        &mut self,
        code: impl Into<String>,
        class: IssueClass,
        severity: IssueSeverity,
        object_id: Option<ObjectId>,
        safe_message: impl Into<String>,
        makes_partial: bool,
    ) {
        let code = code.into();
        if makes_partial {
            self.partial_reasons.insert(code.clone());
        }
        self.issues.push(AttachmentIssue {
            code,
            class,
            severity,
            object_id,
            // An issue is frequently emitted before the corresponding edge is
            // retained. Do not fabricate a positional relationship: callers
            // may still correlate it through the content-addressed object.
            edge_index: None,
            safe_message: safe_message.into(),
        });
    }

    fn record_budget_issue(&mut self, object_id: &ObjectId, error: &AttachmentError) {
        self.issue(
            error.code.clone(),
            IssueClass::Budget,
            IssueSeverity::Blocked,
            Some(object_id.clone()),
            error.safe_message.clone(),
            true,
        );
    }
}

struct CompressedStreamSpec<'a> {
    compressed_source_len: usize,
    raw_name: &'a [u8],
    transform: TransformKind,
    decode_error_code: &'static str,
    decode_error_message: &'static str,
}

struct ZipEntryMetadata {
    index: usize,
    raw_name: Vec<u8>,
    display_name: String,
    size: u64,
    compressed_size: u64,
    directory: bool,
    symlink: bool,
    regular: bool,
    encrypted: bool,
    unix_mode: Option<u32>,
    data_start: Option<u64>,
}

struct SevenZipPending {
    edge: DerivationEdge,
    declared: Option<u64>,
    retain: bool,
    bytes: Vec<u8>,
}

enum PdfChildOutcome {
    Complete,
    PartialContinue,
    PartialStop,
}

enum ReadFailure {
    Budget(AttachmentError),
    Io,
}

fn read_derived_bounded(
    reader: &mut impl Read,
    budget: &mut BudgetLedger,
    compressed_bytes: Option<u64>,
) -> Result<Vec<u8>, ReadFailure> {
    let limit = budget.max_stream_output(compressed_bytes);
    if limit == 0 {
        return Err(ReadFailure::Budget(AttachmentError::budget(
            "total_derived_bytes_exceeded",
            "The cumulative derived-byte budget is exhausted; the decoder was not read.",
        )));
    }
    let initial_capacity = usize::try_from(limit.min(1024 * 1024)).unwrap_or(1024 * 1024);
    let mut output = Vec::with_capacity(initial_capacity);
    let mut chunk = [0_u8; 32 * 1024];
    loop {
        budget.check_deadline().map_err(ReadFailure::Budget)?;
        let produced = u64::try_from(output.len()).map_err(|_| {
            ReadFailure::Budget(AttachmentError::budget(
                "derived_bytes_overflow",
                "A derived object length cannot be represented safely.",
            ))
        })?;
        if produced == limit {
            let mut probe = [0_u8; 1];
            let read = reader.read(&mut probe).map_err(|_| ReadFailure::Io)?;
            if read == 0 {
                break;
            }
            return Err(ReadFailure::Budget(AttachmentError::budget(
                "derived_stream_limit_exceeded",
                "A compressed attachment member exceeded its object, cumulative, or expansion-ratio limit.",
            )));
        }
        let chunk_len = u64::try_from(chunk.len()).unwrap_or(u64::MAX);
        let allowance = usize::try_from((limit - produced).min(chunk_len)).unwrap_or(chunk.len());
        let read = reader
            .read(&mut chunk[..allowance])
            .map_err(|_| ReadFailure::Io)?;
        if read == 0 {
            break;
        }
        let next = u64::try_from(output.len())
            .ok()
            .and_then(|current| current.checked_add(u64::try_from(read).ok()?))
            .ok_or_else(|| {
                ReadFailure::Budget(AttachmentError::budget(
                    "derived_bytes_overflow",
                    "A derived object length cannot be represented safely.",
                ))
            })?;
        if next > limit {
            return Err(ReadFailure::Budget(AttachmentError::budget(
                "derived_stream_limit_exceeded",
                "A compressed attachment member exceeded its object, cumulative, or expansion-ratio limit.",
            )));
        }
        budget
            .charge_derived_chunk(read)
            .map_err(ReadFailure::Budget)?;
        output.extend_from_slice(&chunk[..read]);
    }
    Ok(output)
}

fn format_can_derive(format: DetectedFormat) -> bool {
    matches!(
        format,
        DetectedFormat::Zip
            | DetectedFormat::Docx
            | DetectedFormat::Pptx
            | DetectedFormat::Xlsx
            | DetectedFormat::Epub
            | DetectedFormat::OpenDocumentText
            | DetectedFormat::OpenDocumentSpreadsheet
            | DetectedFormat::OpenDocumentPresentation
            | DetectedFormat::IWorkPages
            | DetectedFormat::IWorkNumbers
            | DetectedFormat::IWorkKeynote
            | DetectedFormat::Tar
            | DetectedFormat::Gzip
            | DetectedFormat::Bzip2
            | DetectedFormat::Xz
            | DetectedFormat::Zstd
            | DetectedFormat::SevenZip
            | DetectedFormat::Email
            | DetectedFormat::Mbox
            | DetectedFormat::Pdf
    )
}

fn zip_mode_is_special(mode: Option<u32>) -> bool {
    const FILE_TYPE_MASK: u32 = 0o170000;
    const REGULAR_FILE: u32 = 0o100000;
    const DIRECTORY: u32 = 0o040000;
    mode.is_some_and(|mode| {
        let kind = mode & FILE_TYPE_MASK;
        kind != 0 && kind != REGULAR_FILE && kind != DIRECTORY
    })
}

fn provenance(kind: TransformKind) -> TransformProvenance {
    TransformProvenance {
        kind,
        implementation: IMPLEMENTATION.to_string(),
        version: VERSION.to_string(),
    }
}

fn sha256(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn saturating_usize(value: u64) -> usize {
    usize::try_from(value).unwrap_or(usize::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use attachment_native_types::{ArchivePathPolicy, BudgetLimits, Coverage, EdgeOutcome};
    use flate2::Compression;
    use flate2::write::GzEncoder;
    use libarchive_oxide::SeekArchiveWriter;
    use libarchive_oxide::libarchive_oxide_core::{ArchivePath, EntryMetadata, FormatId};
    use lopdf::{Document, Object as PdfObject, Stream as PdfStream, dictionary};
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    #[test]
    fn default_inspector_uses_exact_default_policy() {
        assert_eq!(Inspector::default().policy(), &InspectionPolicy::default());
    }

    #[test]
    fn bounded_reader_rejects_at_limit_plus_one_without_trusting_metadata() {
        let error =
            ProvidedAttachment::read_bounded("growing.bin", None, Cursor::new(vec![0_u8; 9]), 8)
                .expect_err("the ninth byte must prove the root exceeds its limit");
        assert_eq!(error.code, "root_bytes_exceeded");
    }

    #[test]
    fn pure_rust_compression_streams_reenter_the_same_object_queue() {
        const BZIP2: &[u8] = &[
            0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0x71, 0x1c, 0x50, 0xc0,
            0x00, 0x00, 0x03, 0xd9, 0x80, 0x00, 0x10, 0x40, 0x00, 0x10, 0x00, 0x3a, 0x44, 0x90,
            0x10, 0x20, 0x00, 0x31, 0x03, 0x40, 0xd0, 0x29, 0x80, 0x1e, 0xa2, 0xe0, 0x4c, 0xed,
            0x69, 0xe0, 0xe1, 0x77, 0x24, 0x53, 0x85, 0x09, 0x07, 0x11, 0xc5, 0x0c, 0x00,
        ];
        const XZ: &[u8] = &[
            0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x04, 0xe6, 0xd6, 0xb4, 0x46, 0x04, 0xc0,
            0x0d, 0x09, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x5f, 0x4f, 0x33, 0xe4, 0x01, 0x00, 0x08, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x78,
            0x7a, 0x0a, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x49, 0x3a, 0xfa, 0x63, 0x52, 0x14, 0x5a,
            0x00, 0x01, 0x29, 0x09, 0x64, 0x92, 0x1c, 0x1d, 0x1f, 0xb6, 0xf3, 0x7d, 0x01, 0x00,
            0x00, 0x00, 0x00, 0x04, 0x59, 0x5a,
        ];
        const ZSTD: &[u8] = &[
            0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x59, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
            0x20, 0x7a, 0x73, 0x74, 0x64, 0x0a, 0x6c, 0x57, 0xf9, 0x51,
        ];
        for (name, bytes, transform) in [
            ("hello.txt.bz2", BZIP2, TransformKind::Bzip2Payload),
            ("hello.txt.xz", XZ, TransformKind::XzPayload),
            ("hello.txt.zst", ZSTD, TransformKind::ZstdPayload),
        ] {
            let bundle = Inspector::default()
                .inspect(ProvidedAttachment::from_bytes(name, None, bytes.to_vec()))
                .expect("compressed fixture must produce a graph");
            assert_eq!(bundle.graph.objects.len(), 2, "{name}");
            assert_eq!(bundle.graph.edges.len(), 1, "{name}");
            assert_eq!(bundle.graph.edges[0].transform.kind, transform, "{name}");
            assert_eq!(
                bundle.graph.edges[0].outcome,
                EdgeOutcome::Derived,
                "{name}"
            );
            assert_eq!(
                bundle.graph.objects[1].detection.selected,
                Some(DetectedFormat::PlainText),
                "{name}"
            );
        }
    }

    fn zip_bytes(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut output = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut output);
            for (name, bytes) in entries {
                writer
                    .start_file(*name, SimpleFileOptions::default())
                    .expect("fixture ZIP entry should start");
                writer
                    .write_all(bytes)
                    .expect("fixture ZIP bytes should write");
            }
            writer.finish().expect("fixture ZIP should finish");
        }
        output.into_inner()
    }

    fn seven_zip_bytes(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let output = Cursor::new(Vec::new());
        let mut writer = SeekArchiveWriter::with_format(output, FormatId::SevenZip, Limits::safe())
            .expect("fixture 7z writer should initialize");
        for (name, bytes) in entries {
            let size = u64::try_from(bytes.len()).expect("fixture member length should fit");
            let metadata = EntryMetadata::builder(
                EntryKind::File,
                ArchivePath::from_utf8((*name).to_string()),
            )
            .size(Some(size))
            .build();
            writer
                .start_entry(&metadata)
                .expect("fixture 7z entry should start");
            writer
                .write_data(bytes)
                .expect("fixture 7z member should write");
            writer.end_entry().expect("fixture 7z entry should end");
        }
        writer
            .finish()
            .expect("fixture 7z should finish")
            .into_inner()
    }

    #[test]
    fn seven_zip_members_reenter_the_iterative_graph_and_deduplicate() {
        let inner = seven_zip_bytes(&[("leaf.md", b"# nested evidence")]);
        let outer = seven_zip_bytes(&[("a-inner.7z", &inner), ("b-copy.7z", &inner)]);
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes("nested.7z", None, outer))
            .expect("bounded 7z inspection should complete");

        assert_eq!(bundle.graph.objects.len(), 3);
        assert_eq!(bundle.graph.edges.len(), 3);
        assert!(
            bundle
                .graph
                .edges
                .iter()
                .all(|edge| { edge.transform.kind == TransformKind::SevenZipMember })
        );
        assert_eq!(
            bundle
                .graph
                .edges
                .iter()
                .filter(|edge| edge.outcome == EdgeOutcome::Duplicate)
                .count(),
            1
        );
        assert!(
            bundle
                .graph
                .objects
                .iter()
                .any(|object| { object.detection.selected == Some(DetectedFormat::Markdown) })
        );
        assert_eq!(bundle.graph.coverage, Coverage::Complete);
    }

    #[test]
    fn seven_zip_entry_limit_rejects_the_whole_attacker_ordered_set() {
        let archive = seven_zip_bytes(&[("a.txt", b"a"), ("b.txt", b"b")]);
        let policy = InspectionPolicy {
            limits: BudgetLimits {
                max_entries: 1,
                ..BudgetLimits::default()
            },
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("wide.7z", None, archive))
            .expect("over-wide 7z should produce an honest graph");

        assert_eq!(bundle.graph.objects.len(), 1);
        assert!(bundle.graph.edges.is_empty());
        assert_eq!(bundle.graph.usage.entries, 0);
        assert!(bundle.graph.issues.iter().any(|issue| {
            issue.code == "seven_zip_native_limit_exceeded" && issue.class == IssueClass::Budget
        }));
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    }

    #[test]
    fn seven_zip_codec_memory_is_bounded_by_the_decoder_window_policy() {
        let archive = seven_zip_bytes(&[("evidence.txt", b"bounded evidence")]);
        let policy = InspectionPolicy {
            limits: BudgetLimits {
                max_decoder_window_bytes: 1,
                ..BudgetLimits::default()
            },
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("window.7z", None, archive))
            .expect("an over-window 7z should produce an honest graph");

        assert_eq!(bundle.graph.objects.len(), 1);
        assert!(bundle.graph.edges.is_empty());
        assert_eq!(bundle.graph.usage.total_derived_bytes, 0);
        assert!(bundle.graph.issues.iter().any(|issue| {
            issue.code == "seven_zip_native_limit_exceeded" && issue.class == IssueClass::Budget
        }));
    }

    #[test]
    fn seven_zip_decoded_total_limit_is_preflighted_before_any_member() {
        let first = vec![b'a'; 40];
        let second = vec![b'b'; 40];
        let archive = seven_zip_bytes(&[("a.txt", &first), ("b.txt", &second)]);
        let policy = InspectionPolicy {
            limits: BudgetLimits {
                max_object_bytes: 50,
                max_total_derived_bytes: 60,
                ..BudgetLimits::default()
            },
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("total.7z", None, archive))
            .expect("over-expanded 7z should produce an honest graph");

        assert!(bundle.graph.edges.is_empty());
        assert_eq!(bundle.graph.usage.total_derived_bytes, 0);
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .any(|issue| issue.code == "seven_zip_native_limit_exceeded")
        );
    }

    #[test]
    fn truncated_seven_zip_is_malformed_not_an_empty_success() {
        let mut archive = seven_zip_bytes(&[("evidence.txt", b"bounded evidence")]);
        archive.truncate(archive.len().saturating_sub(8));
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes(
                "truncated.7z",
                None,
                archive,
            ))
            .expect("truncated 7z should produce an honest graph");

        assert_eq!(bundle.graph.objects.len(), 1);
        assert!(bundle.graph.edges.is_empty());
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .any(|issue| issue.code == "seven_zip_structure_invalid")
        );
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    }

    #[test]
    fn nested_seven_zip_honors_graph_depth_without_stack_recursion() {
        let inner = seven_zip_bytes(&[("leaf.txt", b"leaf")]);
        let outer = seven_zip_bytes(&[("inner.7z", &inner)]);
        let policy = InspectionPolicy {
            limits: BudgetLimits {
                max_depth: 1,
                ..BudgetLimits::default()
            },
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("outer.7z", None, outer))
            .expect("nested 7z should produce an honest graph");

        assert_eq!(bundle.graph.objects.len(), 2);
        assert_eq!(bundle.graph.edges.len(), 2);
        assert_eq!(bundle.graph.edges[1].outcome, EdgeOutcome::DepthExceeded);
        assert_eq!(bundle.graph.usage.deepest_object, 2);
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    }

    #[test]
    fn seven_zip_member_paths_are_inert_metadata() {
        let archive = seven_zip_bytes(&[("../../private.txt", b"bounded")]);
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes("unsafe.7z", None, archive))
            .expect("unsafe member names should never become filesystem authority");

        assert_eq!(bundle.graph.objects.len(), 2);
        assert_eq!(bundle.graph.edges.len(), 1);
        assert_eq!(bundle.graph.edges[0].name.display, "unsafe-member-0");
        assert!(bundle.graph.edges[0].name.sanitized);
        assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::Derived);
    }

    fn pdf_bytes(
        entries: &[(&str, &[u8], bool)],
        include_declared_size: bool,
        include_active_content: bool,
    ) -> Vec<u8> {
        let mut document = Document::with_version("1.7");
        let pages_id = document.add_object(dictionary! {
            "Type" => "Pages",
            "Kids" => Vec::<PdfObject>::new(),
            "Count" => 0_i64,
        });
        let mut names = Vec::with_capacity(entries.len().saturating_mul(2));
        for (name, payload, compress) in entries {
            let media_type = if name.ends_with(".zip") {
                b"application#2Fzip".to_vec()
            } else {
                b"text#2Fplain".to_vec()
            };
            let mut stream_dictionary = dictionary! {
                "Type" => "EmbeddedFile",
                "Subtype" => PdfObject::Name(media_type),
            };
            if include_declared_size {
                stream_dictionary.set(
                    "Params",
                    dictionary! { "Size" => i64::try_from(payload.len()).expect("fixture length") },
                );
            }
            let mut stream = PdfStream::new(stream_dictionary, payload.to_vec());
            if *compress {
                stream
                    .compress()
                    .expect("fixture embedded stream should compress");
            }
            let stream_id = document.add_object(stream);
            let file_spec_id = document.add_object(dictionary! {
                "Type" => "Filespec",
                "F" => PdfObject::string_literal(*name),
                "UF" => PdfObject::string_literal(*name),
                "EF" => dictionary! {
                    "F" => stream_id,
                    "UF" => stream_id,
                },
            });
            names.push(PdfObject::string_literal(*name));
            names.push(PdfObject::Reference(file_spec_id));
        }
        let embedded_names_id = document.add_object(dictionary! { "Names" => names });
        let catalog_id = document.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
            "Names" => dictionary! { "EmbeddedFiles" => embedded_names_id },
        });
        if include_active_content {
            document.add_object(dictionary! {
                "S" => "JavaScript",
                "JS" => PdfObject::string_literal("app.alert('not executed')"),
            });
            document.add_object(dictionary! { "S" => "Launch" });
            document.add_object(dictionary! { "Subtype" => "RichMedia" });
        }
        document.trailer.set("Root", catalog_id);
        document.trailer.set(
            "ID",
            PdfObject::Array(vec![
                PdfObject::string_literal("attachment-native-kit"),
                PdfObject::string_literal("pdf-fixture-v1"),
            ]),
        );
        let mut output = Vec::new();
        document
            .save_to(&mut output)
            .expect("fixture PDF should serialize");
        output
    }

    fn encrypt_pdf_with_empty_password(bytes: &[u8]) -> Vec<u8> {
        let mut document = Document::load_mem(bytes).expect("fixture PDF should reload");
        let version = lopdf::EncryptionVersion::V2 {
            document: &document,
            owner_password: "",
            user_password: "",
            key_length: 128,
            permissions: lopdf::Permissions::all(),
        };
        let state = lopdf::EncryptionState::try_from(version)
            .expect("fixture encryption state should initialize");
        document
            .encrypt(&state)
            .expect("fixture PDF should encrypt");
        let mut output = Vec::new();
        document
            .save_to(&mut output)
            .expect("encrypted fixture PDF should serialize");
        output
    }

    #[test]
    fn pdf_embedded_zip_reenters_the_recursive_inspection_queue() {
        let zip = zip_bytes(&[("inside.txt", b"nested evidence")]);
        let pdf = pdf_bytes(&[("evidence.zip", &zip, true)], true, false);
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes("evidence.pdf", None, pdf))
            .expect("PDF inspection should complete");

        assert_eq!(bundle.graph.objects.len(), 3);
        assert_eq!(bundle.graph.edges.len(), 2);
        assert_eq!(
            bundle.graph.edges[0].transform.kind,
            TransformKind::PdfEmbeddedFile
        );
        assert_eq!(bundle.graph.edges[0].name.display, "evidence.zip");
        assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::Derived);
        assert_eq!(
            bundle.graph.edges[1].transform.kind,
            TransformKind::ZipMember
        );
        assert_eq!(bundle.graph.coverage, Coverage::Complete);
    }

    #[test]
    fn pdf_active_content_is_reported_once_per_class_and_never_executed() {
        let pdf = pdf_bytes(&[], true, true);
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes("active.pdf", None, pdf))
            .expect("PDF inspection should complete");

        for code in [
            "pdf_javascript_detected",
            "pdf_launch_action_detected",
            "pdf_rich_media_detected",
        ] {
            assert_eq!(
                bundle
                    .graph
                    .issues
                    .iter()
                    .filter(|issue| issue.code == code)
                    .count(),
                1,
                "{code} should be deduplicated"
            );
        }
        assert_eq!(bundle.graph.objects.len(), 1);
        assert!(bundle.graph.edges.is_empty());
        assert_eq!(bundle.graph.coverage, Coverage::Complete);
    }

    #[test]
    fn even_empty_password_pdf_encryption_is_an_explicit_unsupported_boundary() {
        let pdf = pdf_bytes(&[("note.txt", b"private", false)], true, false);
        let encrypted = encrypt_pdf_with_empty_password(&pdf);
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes(
                "encrypted.pdf",
                None,
                encrypted,
            ))
            .expect("encrypted PDF should produce an honest graph");

        assert_eq!(bundle.graph.objects.len(), 1);
        assert!(bundle.graph.edges.is_empty());
        assert!(bundle.graph.issues.iter().any(|issue| {
            issue.code == "pdf_encrypted_unsupported" && issue.severity == IssueSeverity::Blocked
        }));
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    }

    #[test]
    fn disabling_pdf_embedded_files_is_an_explicit_partial_result() {
        let pdf = pdf_bytes(&[("note.txt", b"private", false)], true, false);
        let policy = InspectionPolicy {
            inspect_pdf_embedded_files: false,
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("disabled.pdf", None, pdf))
            .expect("PDF inspection should complete");

        assert_eq!(bundle.graph.objects.len(), 1);
        assert!(bundle.graph.edges.is_empty());
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .any(|issue| { issue.code == "pdf_embedded_file_inspection_disabled" })
        );
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    }

    #[test]
    fn pdf_embedded_stream_bomb_stops_after_one_bounded_decode_attempt() {
        let bomb = vec![b'x'; 64 * 1024];
        let pdf = pdf_bytes(
            &[
                ("a-bomb.txt", &bomb, true),
                ("z-after.txt", b"after", false),
            ],
            false,
            false,
        );
        let policy = InspectionPolicy {
            limits: BudgetLimits {
                max_object_bytes: 1_024,
                max_total_derived_bytes: 2_048,
                ..BudgetLimits::default()
            },
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("bomb.pdf", None, pdf))
            .expect("PDF inspection should produce an honest partial graph");

        assert_eq!(bundle.graph.objects.len(), 1);
        assert_eq!(bundle.graph.edges.len(), 1);
        assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::BudgetExceeded);
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .any(|issue| { issue.code == "derived_stream_limit_exceeded" })
        );
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    }

    #[test]
    fn pdf_entry_budget_rejects_the_entire_attacker_ordered_set() {
        let pdf = pdf_bytes(
            &[("a.txt", b"a", false), ("b.txt", b"b", false)],
            true,
            false,
        );
        let policy = InspectionPolicy {
            limits: BudgetLimits {
                max_entries: 1,
                ..BudgetLimits::default()
            },
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("wide.pdf", None, pdf))
            .expect("PDF inspection should produce an honest partial graph");

        assert_eq!(bundle.graph.objects.len(), 1);
        assert!(bundle.graph.edges.is_empty());
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .any(|issue| { issue.code == "archive_entry_limit_exceeded" })
        );
    }

    #[test]
    fn pdf_embedded_file_names_are_inert_and_platform_aliases_do_not_duplicate_edges() {
        let pdf = pdf_bytes(&[("../../private.txt", b"bounded", false)], true, false);
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes("unsafe.pdf", None, pdf))
            .expect("PDF inspection should complete");

        assert_eq!(bundle.graph.objects.len(), 2);
        assert_eq!(bundle.graph.edges.len(), 1);
        assert_eq!(bundle.graph.edges[0].name.display, "unsafe-member-0");
        assert!(bundle.graph.edges[0].name.sanitized);
        assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::Derived);
    }

    #[test]
    fn recursively_inspects_zip_gzip_without_stack_recursion() {
        let mut gzip = GzEncoder::new(Vec::new(), Compression::default());
        gzip.write_all(b"deep evidence")
            .expect("fixture GZIP should write");
        let gzip = gzip.finish().expect("fixture GZIP should finish");
        let zip = zip_bytes(&[("nested.txt.gz", &gzip)]);

        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes("bundle.zip", None, zip))
            .expect("inspection should complete");
        assert_eq!(bundle.graph.objects.len(), 3);
        assert_eq!(bundle.graph.edges.len(), 2);
        assert_eq!(bundle.graph.coverage, Coverage::Complete);
        assert!(
            bundle
                .graph
                .objects
                .iter()
                .any(|object| object.detection.selected == Some(DetectedFormat::PlainText))
        );
    }

    #[test]
    fn traversal_name_is_scanned_under_an_inert_name_and_never_extracted() {
        let zip = zip_bytes(&[("../../private.txt", b"bounded")]);
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes("unsafe.zip", None, zip))
            .expect("inspection should complete");
        assert_eq!(bundle.graph.objects.len(), 2);
        assert!(bundle.graph.edges[0].name.sanitized);
        assert_eq!(bundle.graph.edges[0].name.display, "unsafe-member-0");
        assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::Derived);
    }

    #[test]
    fn strict_path_policy_rejects_but_still_reports_the_member() {
        let zip = zip_bytes(&[("C:\\secret.txt", b"bounded")]);
        let policy = InspectionPolicy {
            path_policy: ArchivePathPolicy::RejectEntry,
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("unsafe.zip", None, zip))
            .expect("inspection should complete");
        assert_eq!(bundle.graph.objects.len(), 1);
        assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::RejectedName);
        assert_eq!(bundle.graph.usage.entries, 1);
        assert_eq!(bundle.graph.usage.edges, 1);
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    }

    #[test]
    fn duplicate_payload_is_analyzed_once_but_keeps_both_edges() {
        let zip = zip_bytes(&[("a.txt", b"same"), ("b.txt", b"same")]);
        let root_bytes = u64::try_from(zip.len()).expect("fixture length fits u64");
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes("duplicates.zip", None, zip))
            .expect("inspection should complete");
        assert_eq!(bundle.graph.objects.len(), 2);
        assert_eq!(bundle.graph.edges.len(), 2);
        assert_eq!(
            bundle
                .graph
                .edges
                .iter()
                .filter(|edge| edge.outcome == EdgeOutcome::Duplicate)
                .count(),
            1
        );
        assert_eq!(bundle.graph.usage.entries, 2);
        assert_eq!(bundle.graph.usage.edges, 2);
        assert_eq!(bundle.graph.usage.objects, 2);
        assert_eq!(bundle.graph.usage.total_derived_bytes, 8);
        assert_eq!(bundle.graph.usage.retained_bytes, root_bytes + 4);
    }

    #[test]
    fn graph_order_status_issues_and_usage_are_deterministic() {
        let zip = zip_bytes(&[
            ("b.txt", b"same"),
            ("../../unsafe.txt", b"unsafe"),
            ("a.txt", b"same"),
        ]);
        let inspect = || {
            Inspector::default()
                .inspect(ProvidedAttachment::from_bytes(
                    "determinism.zip",
                    None,
                    zip.clone(),
                ))
                .expect("inspection should complete")
                .graph
        };

        let first = inspect();
        let mut second = inspect();
        second.job_id = first.job_id.clone();
        assert_eq!(second, first);
    }

    #[test]
    fn entry_budget_blocks_the_whole_attacker_ordered_zip_subset() {
        let zip = zip_bytes(&[("a.txt", b"a"), ("b.txt", b"b")]);
        let policy = InspectionPolicy {
            limits: BudgetLimits {
                max_entries: 1,
                ..BudgetLimits::default()
            },
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("wide.zip", None, zip))
            .expect("inspection should complete");
        assert_eq!(bundle.graph.objects.len(), 1);
        assert!(bundle.graph.edges.is_empty());
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    }

    #[test]
    fn maximum_depth_object_is_analyzed_but_not_derived() {
        let inner = zip_bytes(&[("leaf.txt", b"leaf")]);
        let outer = zip_bytes(&[("inner.zip", &inner)]);
        let policy = InspectionPolicy {
            limits: BudgetLimits {
                max_depth: 1,
                ..BudgetLimits::default()
            },
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("outer.zip", None, outer))
            .expect("inspection should complete");
        assert_eq!(bundle.graph.objects.len(), 2);
        assert_eq!(bundle.graph.edges.len(), 2);
        assert_eq!(bundle.graph.edges[1].outcome, EdgeOutcome::DepthExceeded);
    }

    #[test]
    fn compression_ratio_budget_stops_tiny_bombs() {
        let large = vec![b'x'; 512 * 1024];
        let zip = zip_bytes(&[("bomb.txt", &large)]);
        let policy = InspectionPolicy {
            limits: BudgetLimits {
                max_declared_to_actual_ratio: 2,
                ..BudgetLimits::default()
            },
            ..InspectionPolicy::default()
        };
        let bundle = Inspector::new(policy)
            .expect("policy should be valid")
            .inspect(ProvidedAttachment::from_bytes("bomb.zip", None, zip))
            .expect("inspection should complete");
        assert_eq!(bundle.graph.objects.len(), 1);
        assert_eq!(bundle.graph.edges[0].outcome, EdgeOutcome::BudgetExceeded);
        assert!(matches!(bundle.graph.coverage, Coverage::Partial { .. }));
    }

    #[test]
    fn extension_never_overrides_signature() {
        let bundle = Inspector::default()
            .inspect(ProvidedAttachment::from_bytes(
                "portrait.txt",
                Some("text/plain".to_string()),
                b"\x89PNG\r\n\x1a\nfixture".to_vec(),
            ))
            .expect("inspection should complete");
        assert_eq!(
            bundle.graph.objects[0].detection.selected,
            Some(DetectedFormat::Png)
        );
        assert!(
            bundle
                .graph
                .issues
                .iter()
                .any(|issue| issue.code == "declared_type_mismatch")
        );
    }
}
