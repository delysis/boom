use attachment_native_types::{ArchivePathPolicy, AttachmentError, LogicalName};

pub(crate) struct NameDecision {
    pub(crate) logical: LogicalName,
    pub(crate) accepted: bool,
    pub(crate) reason: Option<&'static str>,
}

pub(crate) fn logical_member_name(
    raw: &[u8],
    entry_index: usize,
    max_bytes: u32,
    policy: ArchivePathPolicy,
) -> Result<NameDecision, AttachmentError> {
    let raw_len = u32::try_from(raw.len()).map_err(|_| {
        AttachmentError::budget(
            "archive_name_limit_exceeded",
            "An archive member name cannot be represented within platform limits.",
        )
    })?;
    if raw_len > max_bytes {
        return Ok(rejected_or_sanitized(
            raw,
            entry_index,
            policy,
            "name_too_long",
        ));
    }

    let decoded = String::from_utf8_lossy(raw);
    let portable = decoded.replace('\\', "/");
    let path_is_absolute = portable.starts_with('/')
        || portable.starts_with("//")
        || portable
            .as_bytes()
            .get(1)
            .is_some_and(|value| *value == b':')
            && portable
                .as_bytes()
                .first()
                .is_some_and(u8::is_ascii_alphabetic);
    let has_nul = raw.contains(&0);
    let has_parent = portable.split('/').any(|component| component == "..");
    let has_control = decoded.chars().any(char::is_control);
    let has_windows_device = portable
        .split('/')
        .filter(|component| !component.is_empty())
        .any(is_windows_device_name);

    if path_is_absolute || has_nul || has_parent || has_windows_device {
        let reason = if path_is_absolute {
            "absolute_path"
        } else if has_nul {
            "nul_in_name"
        } else if has_parent {
            "parent_traversal"
        } else {
            "windows_device_name"
        };
        return Ok(rejected_or_sanitized(raw, entry_index, policy, reason));
    }

    let components = portable
        .split('/')
        .filter(|component| !component.is_empty() && *component != ".")
        .map(sanitize_display_component)
        .collect::<Vec<_>>();
    if components.is_empty() {
        return Ok(rejected_or_sanitized(
            raw,
            entry_index,
            policy,
            "empty_name",
        ));
    }
    let sanitized =
        has_control || !decoded.is_ascii() && matches!(decoded, std::borrow::Cow::Owned(_));
    Ok(NameDecision {
        logical: LogicalName {
            display: components.join("/"),
            raw_name_hex: sanitized.then(|| hex::encode(raw)),
            sanitized,
        },
        accepted: true,
        reason: sanitized.then_some("display_name_sanitized"),
    })
}

fn rejected_or_sanitized(
    raw: &[u8],
    entry_index: usize,
    policy: ArchivePathPolicy,
    reason: &'static str,
) -> NameDecision {
    NameDecision {
        logical: LogicalName {
            display: format!("unsafe-member-{entry_index}"),
            raw_name_hex: Some(hex::encode(raw)),
            sanitized: true,
        },
        accepted: policy == ArchivePathPolicy::SanitizeAndScan,
        reason: Some(reason),
    }
}

fn sanitize_display_component(component: &str) -> String {
    component
        .chars()
        .map(|character| {
            if character.is_control() {
                '\u{fffd}'
            } else {
                character
            }
        })
        .collect()
}

fn is_windows_device_name(component: &str) -> bool {
    let stem = component
        .split('.')
        .next()
        .unwrap_or_default()
        .trim_end_matches([' ', '.'])
        .to_ascii_uppercase();
    matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || stem
            .strip_prefix("COM")
            .or_else(|| stem.strip_prefix("LPT"))
            .is_some_and(|number| {
                number.len() == 1 && number.as_bytes()[0].is_ascii_digit() && number != "0"
            })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn traversal_names_remain_inert_metadata() {
        let result = logical_member_name(
            b"../../etc/passwd",
            3,
            128,
            ArchivePathPolicy::SanitizeAndScan,
        )
        .expect("name policy should complete");
        assert!(result.accepted);
        assert!(result.logical.sanitized);
        assert_eq!(result.logical.display, "unsafe-member-3");
        assert_eq!(result.reason, Some("parent_traversal"));
    }

    #[test]
    fn windows_paths_are_rejected_portably() {
        for raw in [b"C:\\secret.txt".as_slice(), b"folder/NUL.txt".as_slice()] {
            let result = logical_member_name(raw, 0, 128, ArchivePathPolicy::RejectEntry)
                .expect("name policy should complete");
            assert!(!result.accepted);
        }
    }
}
