#ifndef BOOM_ATTACHMENT_H
#define BOOM_ATTACHMENT_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint8_t *data; size_t length; } BoomAttachmentBuffer;
/* Inputs are borrowed only for this call. Returned bytes are UTF-8 JSON, not NUL-terminated. */
BoomAttachmentBuffer boom_attachment_inspect(const uint8_t *name, size_t name_length,
                                            const uint8_t *data, size_t length);
void boom_attachment_free(BoomAttachmentBuffer buffer);
#ifdef __cplusplus
}
#endif
#endif
