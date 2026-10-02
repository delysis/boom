use flate2::Compression;
use flate2::write::GzEncoder;
use std::io::{Cursor, Write};
use zip::write::SimpleFileOptions;

pub fn gzip_bytes(bytes: &[u8]) -> Vec<u8> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(bytes)
        .expect("fixture GZIP bytes should write");
    encoder.finish().expect("fixture GZIP should finish")
}

pub fn zip_bytes(entries: &[(&str, &[u8])]) -> Vec<u8> {
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

pub fn nested_email() -> Vec<u8> {
    br#"From: outer@example.test
To: inspector@example.test
Subject: Outer message
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="outer-boundary"

--outer-boundary
Content-Type: text/plain; charset=utf-8

Outer body.
--outer-boundary
Content-Type: message/rfc822; name="forwarded.eml"
Content-Disposition: attachment; filename="forwarded.eml"
Content-Transfer-Encoding: 7bit

From: inner@example.test
To: inspector@example.test
Subject: Inner message
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="inner-boundary"

--inner-boundary
Content-Type: text/plain; charset=utf-8

Inner body.
--inner-boundary
Content-Type: text/plain; name="evidence.txt"
Content-Disposition: attachment; filename="evidence.txt"

nested evidence
--inner-boundary--
--outer-boundary--
"#
    .to_vec()
}

pub fn email_with_misleading_png_attachment() -> Vec<u8> {
    br#"From: sender@example.test
To: inspector@example.test
Subject: MIME metadata
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="mime-boundary"

--mime-boundary
Content-Type: text/plain; charset=utf-8

Body.
--mime-boundary
Content-Type: image/png; name="misleading.txt"
Content-Disposition: attachment; filename="misleading.txt"
Content-Transfer-Encoding: base64

iVBORw0KGgpmaXh0dXJl
--mime-boundary--
"#
    .to_vec()
}
