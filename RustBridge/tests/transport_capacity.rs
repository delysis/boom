use boom_attachment_ffi::{bloom_core_request, boom_attachment_free};
use serde_json::{json, Value};

const MIB: usize = 1024 * 1024;

fn call(request: &Value) -> Value {
    let bytes = serde_json::to_vec(request).unwrap();
    call_bytes(&bytes)
}

fn call_bytes(bytes: &[u8]) -> Value {
    // SAFETY: the request bytes remain live for the call; the returned buffer is
    // borrowed only until it is freed exactly once below.
    unsafe {
        let result = bloom_core_request(bytes.as_ptr(), bytes.len());
        let value = serde_json::from_slice(std::slice::from_raw_parts(result.data, result.length));
        boom_attachment_free(result);
        value.unwrap()
    }
}

fn history_request(op: &str) -> Value {
    let history: Vec<_> = (0..9)
        .map(|index| {
            json!({"role":"user", "text":format!("{index}{}", "a".repeat(499_999)),
            "speaker":{"name":"Human", "voiceId":null, "voiceRevision":null}})
        })
        .collect();
    json!({"op":op,"voices":[null],"history":history,"instructions":"",
        "context":"","request":"Continue.","routing":[]})
}

#[test]
fn legacy_echo_and_prompt_proof_hit_the_unchanged_reply_limit() {
    let files: Vec<_> = (0..4)
        .map(|index| json!({"path":format!("{index}.md"), "text":"x".repeat(2 * MIB)}))
        .collect();
    let import = json!({"op":"validate_import", "files":files});
    let old_history = history_request("compile_consultation");
    for (label, request) in [
        ("four admitted 2 MiB imports", import),
        ("nine admitted 500 kB turns", old_history),
    ] {
        let request_bytes = serde_json::to_vec(&request).unwrap();
        let value = call_bytes(&request_bytes);
        eprintln!(
            "{label}: request_bytes={} response={value}",
            request_bytes.len()
        );
        assert_eq!(value["error"]["code"], "output_limit");
    }
}

#[test]
fn malformed_request_remains_a_non_budget_failure() {
    assert_eq!(call_bytes(b"{")["error"]["code"], "request_invalid");
    let mut request = history_request("compile_consultation");
    request["history"][8]["role"] = json!("bogus");
    assert_eq!(call(&request)["error"]["code"], "invalid");
}

#[test]
fn acknowledgements_admit_exact_import_budget_without_echoing_text() {
    let files: Vec<_> = (0..4)
        .map(|index| json!({"path":format!("{index}.md"), "text":"x".repeat(2 * MIB)}))
        .collect();
    for op in ["admit_import", "admit_document_import"] {
        let response = call(&json!({"op":op, "files":files}));
        assert_eq!(response["ok"], true);
        assert_eq!(response["value"], true);
        assert!(serde_json::to_vec(&response).unwrap().len() < 128);
    }
    let authored = "\u{feff}# 私\r\ne\u{301} 🧑‍💻 \"\\\n";
    let files = json!([{"path":"Drafts/章.md","text":authored}]);
    assert_eq!(
        call(&json!({"op":"validate_import","files":files}))["value"],
        files
    );
}

#[test]
fn reply_boundary_admits_exact_eight_mib_and_refuses_one_more_encoded_byte() {
    let mut files: Vec<_> = (0..4)
        .map(|index| json!({"path":format!("{index}.md"),"text":"x".repeat(2*MIB)}))
        .collect();
    let envelope = json!({"schema":1,"ok":true,"value":files});
    let overhead = serde_json::to_vec(&envelope).unwrap().len() - 8 * MIB;
    files[3]["text"] = json!("x".repeat(2 * MIB - overhead));
    let expected = json!({"schema":1,"ok":true,"value":files});
    assert_eq!(serde_json::to_vec(&expected).unwrap().len(), 8 * MIB);
    assert_eq!(
        call(&json!({"op":"validate_import","files":files})),
        expected
    );
    files[3]["text"] = json!("x".repeat(2 * MIB - overhead + 1));
    assert_eq!(
        call(&json!({"op":"validate_import","files":files}))["error"]["code"],
        "output_limit"
    );
}

#[test]
fn escaped_imports_fit_individual_admissions_after_global_path_validation() {
    let text = "\u{1}".repeat(2 * MIB); // Six JSON bytes per admitted text byte.
    let files: Vec<_> = (0..4)
        .map(|index| json!({"path":format!("Drafts/{index}.md"), "text":text}))
        .collect();
    let global = call(&json!({"op":"validate_import_budget","files":files.len(),"bytes":8*MIB}));
    assert_eq!(global["value"], true);
    let paths: Vec<_> = files
        .iter()
        .map(|file| json!({"path":file["path"],"text":""}))
        .collect();
    assert_eq!(
        call(&json!({"op":"admit_import","files":paths}))["value"],
        true
    );
    for file in &files {
        let request = json!({"op":"admit_import","files":[file]});
        assert!(serde_json::to_vec(&request).unwrap().len() < 16 * MIB);
        assert_eq!(call(&request)["value"], true);
    }
    let mut invalid_paths = paths;
    invalid_paths[3]["path"] = json!("../last.md");
    assert_eq!(
        call(&json!({"op":"admit_import","files":invalid_paths}))["error"]["code"],
        "invalid"
    );
}

#[test]
fn import_acknowledgements_preserve_non_budget_validation() {
    for op in ["admit_import", "admit_document_import"] {
        for files in [
            json!([]),
            json!([{"path":"a.md","text":"ok"},{"path":"../last.md","text":"ok"}]),
            json!([{"path":"a.md","text":"ok"},{"path":"last.md","text":"bad\0"}]),
            json!([{"path":"large.md","text":"x".repeat(2*MIB+1)}]),
        ] {
            assert_eq!(
                call(&json!({"op":op,"files":files}))["error"]["code"],
                "invalid"
            );
        }
    }
    let duplicate = json!([{"path":"same.md","text":"first"},{"path":"same.md","text":"second"}]);
    assert_eq!(
        call(&json!({"op":"admit_import","files":duplicate}))["error"]["code"],
        "invalid"
    );
    assert_eq!(
        call(&json!({"op":"admit_document_import","files":duplicate}))["value"],
        true
    );
}

fn join(texts: &[Value], indices: &Value) -> String {
    indices
        .as_array()
        .unwrap()
        .iter()
        .map(|index| texts[index.as_u64().unwrap() as usize].as_str().unwrap())
        .collect()
}

#[test]
fn three_voice_history_is_shared_and_preserves_captured_roles_and_bytes() {
    let golden: Value =
        serde_json::from_slice(include_bytes!("fixtures/consultation-preimage.json")).unwrap();
    let voices = golden["request"]["voices"].as_array().unwrap();
    let history: Vec<_> = (0..9).map(|index| {
        let voice = &voices[index % 3];
        let speaker = if index % 2 == 0 {
            json!({"name":"Human","voiceId":null,"voiceRevision":null})
        } else {
            json!({"name":voice["name"],"voiceId":voice["id"],"voiceRevision":voice["revision"]})
        };
        json!({"role":if index % 2 == 0 { "user" } else { "assistant" },
            "text":format!("{index}{}", "a".repeat(499_999)),"speaker":speaker})
    }).collect();
    let request = json!({"op":"compile_consultation_compact","voices":voices,"history":history,
        "instructions":"","context":"","request":"Continue.","routing":[]});
    let response = call(&request);
    assert_eq!(response["ok"], true, "{response}");
    let compact = &response["value"];
    assert_eq!(compact["schema"], 1);
    let texts = compact["texts"].as_array().unwrap();
    for turn in &history {
        assert_eq!(
            texts.iter().filter(|text| **text == turn["text"]).count(),
            1
        );
    }
    let plans = compact["plans"].as_array().unwrap();
    assert_eq!(plans.len(), 3);
    for (plan, voice) in plans.iter().zip(voices) {
        let mut expected: Vec<(String, String)> = Vec::new();
        for turn in &history {
            let own = turn["role"] == "assistant" && turn["speaker"]["voiceId"] == voice["id"];
            let role = if own { "assistant" } else { "user" };
            let text = turn["text"].as_str().unwrap();
            let content = if turn["role"] == "user" || own {
                text.to_owned()
            } else {
                format!("{}:\n{text}", turn["speaker"]["name"].as_str().unwrap())
            };
            if let Some(last) = expected.last_mut().filter(|last| last.0 == role) {
                last.1.push_str("\n\n");
                last.1.push_str(&content);
            } else {
                expected.push((role.into(), content));
            }
        }
        if let Some(last) = expected.last_mut().filter(|last| last.0 == "user") {
            last.1.push_str("\n\nContinue.");
        } else {
            expected.push(("user".into(), "Continue.".into()));
        }
        let messages = plan["messages"].as_array().unwrap();
        assert_eq!(messages.len(), expected.len() + 3); // system and one example exchange
        for (message, (role, content)) in messages[3..].iter().zip(expected) {
            assert_eq!(message["role"], role);
            assert_eq!(join(texts, &message["content"]), content);
        }
        let mut expected_raw = String::from("<bos>");
        for message in messages {
            let role = message["role"].as_str().unwrap();
            let role = if role == "assistant" { "model" } else { role };
            expected_raw.push_str(&format!(
                "<|turn>{role}\n{}<turn|>\n",
                join(texts, &message["content"])
            ));
        }
        expected_raw.push_str("<|turn>model\n<|channel>thought\n<channel|>");
        assert_eq!(join(texts, &plan["rawPrompt"]), expected_raw);
    }
    eprintln!(
        "three voices / nine 500 kB captured turns: request_bytes={} reply_bytes={} pool_pieces={}",
        serde_json::to_vec(&request).unwrap().len(),
        serde_json::to_vec(&response).unwrap().len(),
        texts.len()
    );
    assert!(serde_json::to_vec(&response).unwrap().len() < 8 * MIB);
}

#[test]
fn serialized_request_boundary_remains_sixteen_mib() {
    let mut bytes = br#"{"op":"layout"}"#.to_vec();
    bytes.resize(16 * MIB, b' ');
    assert_eq!(call_bytes(&bytes)["ok"], true);
    bytes.push(b' ');
    assert_eq!(call_bytes(&bytes)["error"]["code"], "input_limit");
}

#[test]
fn escaped_reply_capacity_is_typed_and_does_not_mask_invalid_input() {
    let mut request = history_request("compile_consultation_compact");
    for (index, turn) in request["history"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .enumerate()
    {
        turn["text"] = json!(format!("{index}{}", "\"\\\r\n".repeat(124_999)));
    }
    let bytes = serde_json::to_vec(&request).unwrap();
    assert!(bytes.len() < 16 * MIB);
    assert_eq!(call_bytes(&bytes)["error"]["code"], "output_limit");
    request["history"][8]["role"] = json!("bogus");
    assert_eq!(call(&request)["error"]["code"], "invalid");
    request["history"][8]["role"] = json!("user");
    request["history"].as_array_mut().unwrap().truncate(7);
    let response = call(&request);
    assert_eq!(response["ok"], true, "{response}");
    let compact = &response["value"];
    let content = join(
        compact["texts"].as_array().unwrap(),
        &compact["plans"][0]["messages"][1]["content"],
    );
    let expected = request["history"]
        .as_array()
        .unwrap()
        .iter()
        .map(|turn| turn["text"].as_str().unwrap())
        .chain(std::iter::once("Continue."))
        .collect::<Vec<_>>()
        .join("\n\n");
    assert_eq!(content, expected);
}

#[test]
fn compiled_prompt_budget_remains_typed_and_semantics_fail_first() {
    let mut request = history_request("compile_consultation_compact");
    for turn in request["history"].as_array_mut().unwrap() {
        turn["text"] = json!("<bos>".repeat(MIB / 5));
    }
    assert_eq!(call(&request)["error"]["code"], "consultation_budget");
    request["history"][8]["role"] = json!("bogus");
    assert_eq!(call(&request)["error"]["code"], "invalid");
    request["history"][8]["role"] = json!("user");
    request["authority"] = json!({"mode":"Edit","target":null});
    assert_eq!(call(&request)["error"]["code"], "invalid");
}

#[test]
fn changed_or_duplicate_voice_is_never_a_trimming_signal() {
    let golden: Value =
        serde_json::from_slice(include_bytes!("fixtures/consultation-preimage.json")).unwrap();
    let mut request = golden["request"].clone();
    request["op"] = json!("compile_consultation_compact");
    request["voices"][2]["revision"] = json!("changed");
    assert_eq!(call(&request)["error"]["code"], "invalid");
    request["voices"][2] = request["voices"][0].clone();
    assert_eq!(call(&request)["error"]["code"], "invalid");
}

#[test]
fn explicitly_windowed_original_prose_can_cross_the_old_wire_limit() {
    let voice = bloom_core::validate_voice(
        bloom_core::VoiceDraft {
            id: uuid::Uuid::new_v4(),
            slug: "reader".into(),
            name: "Reader".into(),
            instructions: String::new(),
            examples: vec![bloom_core::Exchange {
                user: "\u{1}".repeat(MIB),
                assistant: "\u{1}".repeat(MIB),
            }],
        },
        &[],
    )
    .unwrap();
    let mut request = json!({"op":"compile_consultation_compact", "voices":[voice], "history":[],
        "instructions":"", "context":"", "request":"\u{1}".repeat(MIB), "routing":[], "workingTextBytes":0, "workingRequestBytes":0});
    let bytes = serde_json::to_vec(&request).unwrap();
    assert!(bytes.len() > 16 * MIB && bytes.len() < 64 * MIB);
    let value = call_bytes(&bytes);
    assert_eq!(value["ok"], true, "{value}");
    assert_eq!(value["value"]["workingWindow"]["request"]["bytes"], MIB);
    assert_eq!(
        value["value"]["workingWindow"]["voices"][0]["omittedExamples"],
        1
    );
    assert!(serde_json::to_vec(&value).unwrap().len() < 4_096);
    request.as_object_mut().unwrap().remove("workingTextBytes");
    request.as_object_mut().unwrap().remove("workingRequestBytes");
    assert_eq!(call(&request)["error"]["code"], "input_limit");
}
