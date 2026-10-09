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
BoomAttachmentBuffer bloom_media_admit(const uint8_t *data, size_t length);
/* Success returns binary WAV bytes; failure returns a JSON error object. */
BoomAttachmentBuffer bloom_caf_wave(const uint8_t *data, size_t length);
#ifdef __cplusplus
}
#endif
#endif
