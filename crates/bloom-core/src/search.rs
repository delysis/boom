//! Literal live search. Ranges refer to the unmodified source's UTF-16 units.
use super::{Error, TEXT_LIMIT, require};
use regex::RegexBuilder;
use serde::Serialize;

#[derive(Serialize)]
pub struct TextRange {
    location: usize,
    length: usize,
}
#[derive(Serialize)]
pub struct Matches {
    ranges: Vec<TextRange>,
    omitted: usize,
}

pub fn search(text: &str, query: &str) -> Result<Matches, Error> {
    require(
        text.len() <= TEXT_LIMIT && query.len() <= 512,
        "Search exceeds its text or query limit.",
    )?;
    let query = query.trim();
    if query.is_empty() {
        return Ok(Matches {
            ranges: vec![],
            omitted: 0,
        });
    }
    let pattern = RegexBuilder::new(&regex::escape(query))
        .case_insensitive(true)
        .unicode(true)
        .build()
        .map_err(|e| Error(e.to_string()))?;
    let mut result = Matches {
        ranges: vec![],
        omitted: 0,
    };
    let mut cursor = 0;
    let mut utf16 = 0;
    for found in pattern.find_iter(text) {
        if result.ranges.len() == 1024 {
            result.omitted += 1;
            continue;
        }
        utf16 += text[cursor..found.start()].encode_utf16().count();
        let length = text[found.range()].encode_utf16().count();
        result.ranges.push(TextRange {
            location: utf16,
            length,
        });
        utf16 += length;
        cursor = found.end();
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn live_search_is_literal_case_insensitive_and_unicode_source_bound() -> Result<(), Error> {
        let source = "👩‍💻 Café and CAFÉ; [a.*] is literal.\n";
        let found = search(source, "café")?;
        assert_eq!(found.ranges.len(), 2);
        assert_eq!(found.ranges[0].location, 6);
        assert_eq!(found.ranges[0].length, 4);
        let literal = search(source, "[a.*]")?;
        assert_eq!(literal.ranges.len(), 1);
        assert!(search(source, "  ")?.ranges.is_empty());
        let repeated = search(&"x ".repeat(1030), "x")?;
        assert_eq!(repeated.ranges.len(), 1024);
        assert_eq!(repeated.omitted, 6);
        Ok(())
    }
}
