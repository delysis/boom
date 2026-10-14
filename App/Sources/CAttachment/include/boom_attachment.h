#ifndef BOOM_ATTACHMENT_H
#define BOOM_ATTACHMENT_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint8_t *data; size_t length; } BoomAttachmentBuffer;
/* Nonempty inputs borrow readable immutable memory for the duration of the call.
 * Every returned buffer is owned; release it exactly once with boom_attachment_free.
 * Preserve the returned pointer and length. JSON results are not NUL-terminated. */
BoomAttachmentBuffer boom_attachment_inspect(const uint8_t *name, size_t name_length,
                                            const uint8_t *data, size_t length);
void boom_attachment_free(BoomAttachmentBuffer buffer);
BoomAttachmentBuffer bloom_core_request(const uint8_t *data, size_t length);
/* Borrow raw UTF-8 text; empty text may use a null pointer. Results retain the
 * same bounded JSON envelope and exactly-once free contract as core_request. */
BoomAttachmentBuffer bloom_markdown_spans(const uint8_t *data, size_t length);
BoomAttachmentBuffer bloom_markdown_media_spans(const uint8_t *data, size_t length);
BoomAttachmentBuffer bloom_media_admit(const uint8_t *data, size_t length);
/* Success returns binary WAV bytes; failure returns a JSON error object. */
BoomAttachmentBuffer bloom_caf_wave(const uint8_t *data, size_t length);
/* Paged text is a separate host storage boundary, never a model request.
 * Create one engine for all document sessions: it owns one bounded 8 MiB cache.
 * Calls run on a serialized storage executor. No pathname crosses here.
 * Callbacks return 0 on success and set written <= output capacity; any other
 * status fails the operation. They cannot unwind, retain borrowed buffers or
 * reenter a request. Rust checks bounded page digests independently.
 * read_page metadata: {ownerId,documentId,kind,page,maximumBytes}; kind is text
 * or index. Output plaintext <=64KiB(text) or16KiB(index).
 * write_page metadata: {ownerId,documentId,kind}; plaintext is borrowed; reply
 * is bounded JSON {storage:"file_v1",storeId,offset,bytes}; offsets name
 * immutable frames in the captured document's append file.
 * Streams transfer <=64KiB/callback; read success with written=0 means EOF.
 * Cancellation is a nonblocking flag check. Operation context lives until its
 * request returns; host context lives until close returns1 (all callbacks joined).
 * Current-root CAS, permissions, file synchronization and retained-root GC are
 * host responsibilities. A returned revision is neither durable nor a full SHA.
 * Request JSON <=2MiB; reply <=1MiB, free once with boom_attachment_free.
 * Ops: open/window/splice/delete_user_range/checkout/position/stats and the
 * cooperative bulk operations below, with camelCase fields. Splice requires exact oldText and newText, each
 * <=128KiB; delete_user_range is reserved for an explicit user's large deletion.
 * Window fields include byteStart and maximumBytes. Other source operations
 * carry an explicit typed revision.
 * import_begin(ownerId,documentId,expectedBytes), export_begin(revision) and
 * hash_begin(revision) return an opaque UUID operationId. At most two sessions
 * are resident. They retain bounded tree/buffer state, never operation contexts.
 * import_step(ownerId,documentId,operationId) and
 * stream_step(revision,operationId) return cumulative
 * {processedBytes,validatedBytes,complete}. One step processes <=64KiB and a
 * separately bounded number of tree/piece operations. Short reads fill one
 * fixed page buffer; short writes keep an unwritten suffix for the next step.
 * import_step performs at most one read callback; stream_step at most one write.
 * complete=true includes bounded tree finalization and exact extent/EOF checks.
 * import_finish(ownerId,documentId,operationId) consumes a ready imported result;
 * stream_finish(revision,operationId) consumes its real wholeTextSha256 string.
 * Finish does no whole-file work. The host checks the retained input descriptor
 * at EOF and synchronizes export output outside the engine/edit queue.
 * bulk_abort(ownerId,documentId,operationId) is idempotent for an absent token;
 * a foreign active token cannot be accessed or cancelled. Owned step errors
 * discard the session; unpublished page frames belong to host GC.
 * Operation callback pointers are borrowed for one request only. Legacy
 * monolithic import/export/hash operations are rejected.
 */
typedef int32_t (*BloomTextPageRead)(void *, const uint8_t *, size_t,
                                    uint8_t *, size_t, size_t *);
typedef int32_t (*BloomTextPageWrite)(void *, const uint8_t *, size_t,
                                     const uint8_t *, size_t, uint8_t *, size_t, size_t *);
typedef int32_t (*BloomTextStreamRead)(void *, uint8_t *, size_t, size_t *);
typedef int32_t (*BloomTextStreamWrite)(void *, const uint8_t *, size_t, size_t *);
typedef uint8_t (*BloomTextCancelled)(void *);
typedef struct {
  /* Only schema3 and tagged file_v1 locators are admitted.
   * Layout/callback borrowing and close join are unchanged.
   * discard_page_cache_after_rollback clears bounded cache, never proves a
   * durable outcome or aborts an owned producer. The host joins bulk_abort. */
  uint32_t schema; void *context;
  BloomTextPageRead read_page; BloomTextPageWrite write_page;
} BloomTextHost;
typedef struct {
  void *context; BloomTextStreamRead read_stream;
  BloomTextStreamWrite write_stream; BloomTextCancelled is_cancelled;
} BloomTextOperation;
uint64_t bloom_text_create(BloomTextHost host);
/* 0 means busy/unknown; retain the context. 1 means fully closed/joined. */
uint8_t bloom_text_close(uint64_t handle);
BoomAttachmentBuffer bloom_text_request(uint64_t handle, const uint8_t *data,
                                        size_t length, BloomTextOperation operation);
/* One-shot read of a pinned immutable revision. No engine slot/writer mutex,
 * write callback or publication authority. Host schema3, write_page=NULL,
 * revision JSON<=16KiB, display<=16KiB; context borrowed only until return. */
BoomAttachmentBuffer bloom_text_read_window(BloomTextHost host, const uint8_t *revision,
                                           size_t length, uint64_t utf16_offset,
                                           size_t maximum_bytes, BloomTextOperation operation);
/* Native logical source values are distinct from file revisions and publisher
 * records. Edits/Undo do no I/O and never acquire a writer engine slot. The
 * native owner serializes source calls; snapshots/windows are immutable and
 * reference-counted. Keep every handle alive through borrowers, then free it.
 * A returned window borrows UTF8 only for its retained lifetime. Source edit
 * endpoints come from that exact current window's scalar proof.
 * Source replace preserves the physical local edited range through the outer
 * Cocoa transaction; window_trim runs separately after that transaction.
 * Capture(freeze=1) closes the insertion tail before a publication can yield.
 * Materialize runs on the existing writer, returns only a candidate revision;
 * normal page sync + complete-root CAS/publication and native receiving still
 * have to join. release_synced_insertions frees RAM only after real data sync.
 * read_window uses the existing read-only host, no EngineSlot/publication right.
 * Each int function returns0 on success,1 on failure. The error buffer is empty
 * on success, otherwise owned bounded JSON; free with boom_attachment_free. */
typedef struct BloomLogicalCommand BloomLogicalCommand;
typedef struct BloomLogicalSource BloomLogicalSource;
typedef struct BloomLogicalSnapshot BloomLogicalSnapshot;
typedef struct BloomLogicalWindow BloomLogicalWindow;
typedef struct BloomLogicalWindowSeed BloomLogicalWindowSeed;
typedef struct { uint64_t bytes, utf16, lf_count; } BloomLogicalPoint;
typedef struct {
  uint8_t root_id[16], owner_id[16], document_id[16]; BloomLogicalPoint summary;
} BloomLogicalSnapshotInfo;
typedef struct {
  uint8_t root_id[16], window_id[16]; BloomLogicalPoint start, summary;
  const uint8_t *text; size_t text_length;
} BloomLogicalWindowInfo;
int32_t bloom_logical_source_create(const uint8_t *, size_t, BloomLogicalSource **, BoomAttachmentBuffer *);
void bloom_logical_source_free(BloomLogicalSource *);
void bloom_logical_source_install_prepared(const BloomLogicalSource *source, const BloomLogicalSnapshot *snapshot);
int32_t bloom_logical_source_opening_window(const BloomLogicalSource *source, const uint8_t *bytes, size_t length, const BloomLogicalWindow **output, BoomAttachmentBuffer *error);
int32_t bloom_logical_window_seed(const BloomLogicalWindow *window, uint64_t focus_utf16, const BloomLogicalWindowSeed **output, BoomAttachmentBuffer *error);
int32_t bloom_logical_seed_window(const BloomLogicalWindowSeed *seed, const BloomLogicalWindow **output, BoomAttachmentBuffer *error);
typedef struct { BloomLogicalPoint start; BloomLogicalPoint summary; } BloomLogicalSeedInfo;
int32_t bloom_logical_seed_info(const BloomLogicalWindowSeed *seed, BloomLogicalSeedInfo *output);
void bloom_logical_seed_free(const BloomLogicalWindowSeed *seed);
int32_t bloom_logical_source_prepare_replacement(const BloomLogicalSource *source, const BloomLogicalWindow *window, uint64_t first_utf16, uint64_t last_utf16, const uint8_t *insertion, size_t insertion_length, const BloomLogicalWindow **output, BloomLogicalPoint *cursor, uint8_t *changed, uint8_t *resident, BoomAttachmentBuffer *error);
int32_t bloom_logical_source_capture(const BloomLogicalSource *, uint8_t freeze,
                                    const BloomLogicalSnapshot **, BoomAttachmentBuffer *);
int32_t bloom_logical_source_restore(const BloomLogicalSource *, const BloomLogicalSnapshot *, BoomAttachmentBuffer *);
int32_t bloom_logical_source_replace(const BloomLogicalSource *, const BloomLogicalWindow *, size_t byte_start, size_t byte_end,
                                    const uint8_t *insertion, size_t insertion_length,
                                    const BloomLogicalWindow **, BloomLogicalPoint *cursor, uint8_t *changed, BoomAttachmentBuffer *);
int32_t bloom_logical_window_trim(const BloomLogicalWindow *, uint64_t local_focus_utf16, size_t maximum_bytes,
                                 const BloomLogicalWindow **, BoomAttachmentBuffer *);
int32_t bloom_logical_window_info(const BloomLogicalWindow *, BloomLogicalWindowInfo *);
int32_t bloom_logical_window_position(const BloomLogicalWindow *, uint64_t local_utf16, BloomLogicalPoint *, BoomAttachmentBuffer *);
int32_t bloom_logical_window_snapshot(const BloomLogicalWindow *, const BloomLogicalSnapshot **);
int32_t bloom_logical_snapshot_info(const BloomLogicalSnapshot *, BloomLogicalSnapshotInfo *);
void bloom_logical_snapshot_retain(const BloomLogicalSnapshot *);
void bloom_logical_snapshot_free(const BloomLogicalSnapshot *);
void bloom_logical_window_retain(const BloomLogicalWindow *);
void bloom_logical_window_free(const BloomLogicalWindow *);
int32_t bloom_logical_read_window(BloomTextHost, const BloomLogicalSnapshot *, uint64_t utf16_anchor, size_t maximum_bytes,
                                 BloomTextOperation, const BloomLogicalWindow **, BoomAttachmentBuffer *);
int32_t bloom_logical_prepare_replacement(BloomTextHost, const BloomLogicalSnapshot *, uint64_t first_utf16, uint64_t last_utf16, const uint8_t *insertion, size_t insertion_length, BloomTextOperation, const BloomLogicalWindow **output, BloomLogicalPoint *cursor, uint8_t *changed, BoomAttachmentBuffer *error);
int32_t bloom_logical_read_position(BloomTextHost, const BloomLogicalSnapshot *, uint64_t utf16_offset, uint8_t rounding, BloomTextOperation, BloomLogicalPoint *output, BoomAttachmentBuffer *error);
int32_t bloom_logical_read_bytes(BloomTextHost host, const BloomLogicalSnapshot *snapshot,
    uint64_t first, uint64_t last, BloomTextOperation operation, BoomAttachmentBuffer *output,
    BoomAttachmentBuffer *error);
int32_t bloom_logical_command_begin(BloomTextHost host, const BloomLogicalSnapshot *snapshot,
    const uint8_t *json, size_t length, BloomTextOperation operation, BloomLogicalCommand **output, BoomAttachmentBuffer *error);
int32_t bloom_logical_command_step(BloomTextHost host, const BloomLogicalCommand *command,
    BloomTextOperation operation, BoomAttachmentBuffer *output, BoomAttachmentBuffer *error);
int32_t bloom_logical_command_writer_step(uint64_t handle, const BloomLogicalCommand *command,
  BloomTextOperation operation, BoomAttachmentBuffer *output, BoomAttachmentBuffer *error);
int32_t bloom_logical_command_finish(const BloomLogicalCommand *command, const BloomLogicalWindow **window,
    BoomAttachmentBuffer *output, BoomAttachmentBuffer *error);
void bloom_logical_command_free(BloomLogicalCommand *command);

/* Root/window-bound derived Markdown. Begin/append steps use the existing
 * writer engine with immutable source claims; only index pages are written.
 * Query steps use the existing independent readonly host. Every step joins
 * before free; no source adoption, durable publication, or fsync occurs. */
typedef struct BloomLogicalMarkup BloomLogicalMarkup;
int32_t bloom_logical_markup_begin(const BloomLogicalWindow *window,
  uint8_t mode, BloomLogicalMarkup **output, BoomAttachmentBuffer *error);
int32_t bloom_logical_markup_bind_window(const BloomLogicalMarkup *command,
  const BloomLogicalWindow *window, BoomAttachmentBuffer *output, BoomAttachmentBuffer *error);
int32_t bloom_logical_markup_writer_step(uint64_t handle, const BloomLogicalMarkup *command,
  BloomTextOperation operation, BoomAttachmentBuffer *output, BoomAttachmentBuffer *error);
int32_t bloom_logical_markup_step(BloomTextHost host, const BloomLogicalMarkup *command,
  BloomTextOperation operation, BoomAttachmentBuffer *output, BoomAttachmentBuffer *error);
/* Complete progress means a bounded window result is ready; final additionally
   means indexing joined. Taking an early result retains the SAME builder. */
int32_t bloom_logical_markup_finish(const BloomLogicalMarkup *command,
  BloomTextOperation operation, BoomAttachmentBuffer *output, BoomAttachmentBuffer *error);
void bloom_logical_markup_free(BloomLogicalMarkup *command);

BoomAttachmentBuffer bloom_text_materialize_logical(uint64_t, const BloomLogicalSnapshot *, BloomTextOperation);
int32_t bloom_logical_release_synced_insertions(const BloomLogicalSnapshot *, BoomAttachmentBuffer *);
#ifdef __cplusplus
}
#endif
#endif
