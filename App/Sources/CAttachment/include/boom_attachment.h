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
#ifdef __cplusplus
}
#endif
#endif
