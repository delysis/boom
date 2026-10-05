//! A product build has one primary surface; panes and commands share this definition.
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Layout {
    pub edition: &'static str,
    pub primary_pane: &'static str,
    pub panes: &'static [&'static str],
    pub pane_controls: &'static [&'static str],
}

pub fn compiled_layout() -> Layout {
    if cfg!(feature = "chat-layout") {
        Layout {
            edition: "chat",
            primary_pane: "chat",
            panes: &["library", "chat"],
            pane_controls: &["library"],
        }
    } else {
        Layout {
            edition: "author",
            primary_pane: "document",
            panes: &["library", "document", "chat"],
            pane_controls: &["library", "chat"],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pane_controls_only_toggle_secondary_panes_of_the_compiled_product() {
        let layout = compiled_layout();
        assert!(layout.panes.contains(&layout.primary_pane));
        assert!(!layout.pane_controls.contains(&layout.primary_pane));
        for pane in layout.pane_controls {
            assert!(layout.panes.contains(pane));
        }
        if cfg!(feature = "chat-layout") {
            assert!(!layout.panes.contains(&"document"));
            assert_eq!(layout.pane_controls, &["library"]);
        } else {
            assert_eq!(layout.primary_pane, "document");
            assert_eq!(layout.pane_controls, &["library", "chat"]);
        }
    }
}
