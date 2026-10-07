//! Three-way text merge. Coordinates come from a full captured base, never a
//! fuzzy search in the current manuscript. Diff units are Unicode graphemes.
use crate::{Error, require};
use similar::{Algorithm, DiffOp, capture_diff_slices_deadline};
use std::ops::Range;
use std::time::{Duration, Instant};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, PartialEq, Eq)]
pub struct Change<'a> {
    pub range: Range<usize>,
    pub text: &'a str,
}
pub fn minimal<'a>(base: &str, changed: &'a str) -> Result<Vec<Change<'a>>, Error> {
    changes(base, changed, false)
}

fn changes<'a>(base: &str, changed: &'a str, reverse: bool) -> Result<Vec<Change<'a>>, Error> {
    let mut old: Vec<_> = base.graphemes(true).collect();
    let mut new: Vec<_> = changed.graphemes(true).collect();
    if reverse {
        old.reverse();
        new.reverse();
    }
    let offsets = |parts: &[&str]| {
        std::iter::once(0)
            .chain(parts.iter().scan(0, |offset, part| {
                *offset += part.len();
                Some(*offset)
            }))
            .collect::<Vec<_>>()
    };
    let old_offsets = offsets(&old);
    let new_offsets = offsets(&new);
    let deadline = Instant::now() + Duration::from_millis(100);
    let operations = capture_diff_slices_deadline(Algorithm::Myers, &old, &new, Some(deadline));
    // A timed-out diff may conservatively report a replacement. Never use an
    // incomplete alignment to move an edit into an unrelated passage.
    require(
        Instant::now() < deadline,
        "The current manuscript needs a fresh edit plan.",
    )?;
    let mut result = Vec::new();
    for op in operations {
        if matches!(op, DiffOp::Equal { .. }) {
            continue;
        }
        let a = op.old_range();
        let b = op.new_range();
        let old_range = if reverse {
            base.len() - old_offsets[a.end]..base.len() - old_offsets[a.start]
        } else {
            old_offsets[a.start]..old_offsets[a.end]
        };
        let new_range = if reverse {
            changed.len() - new_offsets[b.end]..changed.len() - new_offsets[b.start]
        } else {
            new_offsets[b.start]..new_offsets[b.end]
        };
        result.push(Change {
            range: old_range,
            text: &changed[new_range],
        });
    }
    require(
        result.len() <= 4096,
        "Too many intervening text changes; request a fresh edit.",
    )?;
    result.sort_by_key(|change| change.range.start);
    Ok(result)
}

fn conflict(a: &Range<usize>, b: &Range<usize>) -> bool {
    if a.is_empty() && b.is_empty() {
        a.start == b.start
    } else if a.is_empty() {
        b.start <= a.start && a.start <= b.end
    } else if b.is_empty() {
        a.start < b.start && b.start < a.end
    } else {
        a.start < b.end && b.start < a.end
    }
}

pub fn rebase<'a>(base: &str, current: &str, proposed: &'a str) -> Result<Vec<Change<'a>>, Error> {
    if current == proposed {
        return Ok(Vec::new());
    }
    let theirs = changes(base, proposed, false)?;
    if current == base {
        return Ok(theirs);
    }
    let forward = align(base, current, changes(base, current, false)?, &theirs)?;
    let backward = align(base, current, changes(base, current, true)?, &theirs)?;
    require(
        forward == backward,
        "Repeated passages make this edit's current location ambiguous.",
    )?;
    Ok(forward)
}

fn align<'a>(
    base: &str,
    current: &str,
    ours: Vec<Change<'_>>,
    theirs: &[Change<'a>],
) -> Result<Vec<Change<'a>>, Error> {
    let mut merged = Vec::new();
    for edit in theirs {
        if ours
            .iter()
            .any(|human| human.range == edit.range && human.text == edit.text)
        {
            continue; // The user already made exactly this change.
        }
        let mut offset = 0_isize;
        for human in &ours {
            require(
                !conflict(&edit.range, &human.range),
                "These changes conflict with your current manuscript.",
            )?;
            if human.range.end <= edit.range.start {
                offset += human.text.len() as isize - human.range.len() as isize;
            }
        }
        let start = edit
            .range
            .start
            .checked_add_signed(offset)
            .ok_or_else(|| Error("Invalid merged boundary.".into()))?;
        let end = edit
            .range
            .end
            .checked_add_signed(offset)
            .ok_or_else(|| Error("Invalid merged boundary.".into()))?;
        require(
            current.get(start..end) == base.get(edit.range.clone()),
            "The changed passage cannot be relocated unambiguously.",
        )?;
        merged.push(Change {
            range: start..end,
            text: edit.text,
        });
    }
    Ok(merged)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn apply(base: &str, current: &str, proposed: &str) -> Result<String, Error> {
        let edits = rebase(base, current, proposed)?;
        let mut result = current.to_owned();
        for edit in edits.into_iter().rev() {
            result.replace_range(edit.range, edit.text);
        }
        Ok(result)
    }
    #[test]
    fn independent_same_line_changes_and_shifts_preserve_human_text() -> Result<(), Error> {
        assert_eq!(
            apply(
                "The harbor was quiet.",
                "The harbor was quiet. Human addition.",
                "The harbor was bright."
            )?,
            "The harbor was bright. Human addition."
        );
        assert_eq!(
            apply(
                "The harbor was quiet.",
                "A preface. The harbor was quiet.",
                "The harbor was bright."
            )?,
            "A preface. The harbor was bright."
        );
        assert_eq!(
            apply(
                "The harbor was quiet.",
                "The port was quiet.",
                "The harbor was bright."
            )?,
            "The port was bright."
        );
        assert_eq!(
            apply(
                "👩‍💻 Café waited.\r\nSecond.",
                "👩‍💻 Café waited.\r\nSecond. More.",
                "👩‍💻 Café left.\r\nSecond."
            )?,
            "👩‍💻 Café left.\r\nSecond. More."
        );
        Ok(())
    }
    #[test]
    fn same_change_is_idempotent_but_overlapping_changes_and_same_gap_conflict() -> Result<(), Error>
    {
        assert_eq!(apply("quiet", "bright", "bright")?, "bright");
        for (base, human, model) in [
            ("quiet", "loud", "bright"),
            ("a b", "a human b", "a model b"),
            ("original", "", "revised"),
        ] {
            assert!(
                apply(base, human, model).is_err(),
                "{base} / {human} / {model}"
            );
        }
        Ok(())
    }
    #[test]
    fn repeated_passages_cannot_move_an_edit_to_an_arbitrary_copy() {
        assert!(
            apply(
                "Same.\nSame.\n",
                "Same.\nSame.\nSame.\n",
                "Same.\nChanged.\n"
            )
            .is_err()
        );
    }
}
