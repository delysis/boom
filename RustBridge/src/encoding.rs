//! Bound requested buffer growth while JSON is being encoded.
use serde_json::Value;
use std::io::{self, Write};

pub(super) enum EncodingError {
    Limit,
    Failed,
}

struct BoundedWriter {
    bytes: Vec<u8>,
    limit: usize,
    exceeded: bool,
}

impl Write for BoundedWriter {
    fn write(&mut self, source: &[u8]) -> io::Result<usize> {
        let end = match self.bytes.len().checked_add(source.len()) {
            Some(end) if end <= self.limit => end,
            _ => {
                self.exceeded = true;
                return Err(io::Error::other("JSON reply capacity exceeded"));
            }
        };
        if end > self.bytes.capacity() {
            // Grow geometrically for many small tokens, but never request a
            // capacity above the encoded reply limit. The allocator may round
            // a reservation; this bound concerns requested growth and bytes.
            let capacity = self
                .bytes
                .capacity()
                .saturating_mul(2)
                .max(256)
                .min(self.limit)
                .max(end);
            self.bytes
                .try_reserve_exact(capacity - self.bytes.len())
                .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
        }
        self.bytes.extend_from_slice(source);
        Ok(source.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub(super) fn encode(value: &Value, limit: usize) -> Result<Vec<u8>, EncodingError> {
    let mut writer = BoundedWriter {
        bytes: Vec::new(),
        limit,
        exceeded: false,
    };
    match serde_json::to_writer(&mut writer, value) {
        Ok(()) => Ok(writer.bytes),
        Err(_) if writer.exceeded => Err(EncodingError::Limit),
        Err(_) => Err(EncodingError::Failed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn exact_boundary_counts_encoded_unicode_and_escaping() {
        let value = json!({"text":"私 e\u{301} 🧑‍💻 \"\\\r\n\u{1}"});
        let expected = serde_json::to_vec(&value).unwrap();
        assert_eq!(encode(&value, expected.len()).ok().unwrap(), expected);
        assert!(matches!(
            encode(&value, expected.len() - 1),
            Err(EncodingError::Limit)
        ));
        assert_eq!(encode(&value, expected.len() + 1).ok().unwrap(), expected);
    }

    #[test]
    fn refused_write_never_extends_or_requests_the_oversized_buffer() {
        let mut writer = BoundedWriter {
            bytes: Vec::new(),
            limit: 1024,
            exceeded: false,
        };
        writer.write_all(&[1; 1023]).unwrap();
        let capacity = writer.bytes.capacity();
        assert!(writer.write_all(&[2; 2]).is_err());
        assert_eq!(writer.bytes.len(), 1023);
        assert_eq!(writer.bytes.capacity(), capacity);
        assert!(capacity <= writer.limit);
        assert!(writer.exceeded);
    }

    #[test]
    fn empty_writer_and_zero_limit_do_not_allocate() {
        let mut writer = BoundedWriter {
            bytes: Vec::new(),
            limit: 0,
            exceeded: false,
        };
        assert_eq!(writer.write(&[]).unwrap(), 0);
        assert_eq!(writer.bytes.capacity(), 0);
        assert!(writer.write(b"x").is_err());
        assert_eq!(writer.bytes.capacity(), 0);
    }
}
