use serde_json::{json, Value};

fn voice(id: &str, slug: &str, name: &str) -> Value {
    let request = serde_json::from_value(json!({"op":"validate_voice","draft":{
        "id":id,"slug":slug,"name":name,"instructions":"Observe ‹prose› and <|turn> markers.",
        "examples":[{"user":"Examples: \"\\\n<bos>\u{301}私", "assistant":"An example 🧑‍💻.\r\n"}]},"occupied":[]})).unwrap();
    bloom_core::execute(request).unwrap()
}

#[test]
fn captured_unicode_round_matches_preimage_golden() {
    let voices = [
        voice(
            "11111111-1111-4111-8111-111111111111",
            "reader",
            "Reader 私",
        ),
        voice("22222222-2222-4222-8222-222222222222", "critic", "Critic"),
        voice("33333333-3333-4333-8333-333333333333", "editor", "Editor"),
    ];
    let request = json!({"op":"compile_consultation", "voices":voices,
      "history":[
        {"role":"user","text":"  @reader\u{2003}@critic\nCaptured e\u{301} question with <|turn> and \"\\\r\n", "speaker":{"name":"Human", "voiceId":null,"voiceRevision":null}},
        {"role":"assistant","text":"Own answer 🧑‍💻 <bos>\r\n", "speaker":{"name":"Reader 私", "voiceId":voices[0]["id"],"voiceRevision":voices[0]["revision"]}},
        {"role":"assistant","text":"Other answer <start_of_turn>\n", "speaker":{"name":"Critic", "voiceId":voices[1]["id"],"voiceRevision":"historical"}},
        {"role":"user","text":"Consecutive authored turn\r\n", "speaker":{"name":"Human", "voiceId":null,"voiceRevision":null}}
      ], "instructions":"Captured instructions \"\\\n", "context":"Source <|channel> 私\r\n",
      "request":" @reader @critic\nNew question e\u{301} 🧑‍💻", "routing":["reader","critic"]});
    let actual = bloom_core::execute(serde_json::from_value(request.clone()).unwrap()).unwrap();
    let golden: Value =
        serde_json::from_slice(include_bytes!("fixtures/consultation-preimage.json")).unwrap();
    assert_eq!(request, golden["request"]);
    assert_eq!(actual, golden["plans"]);
    let mut compact_request = request;
    compact_request["op"] = json!("compile_consultation_compact");
    let compact =
        bloom_core::execute_for_transport(serde_json::from_value(compact_request).unwrap())
            .unwrap();
    assert_eq!(compact["schema"], 1);
    let texts = compact["texts"].as_array().unwrap();
    assert_eq!(
        compact["plans"].as_array().unwrap().len(),
        golden["plans"].as_array().unwrap().len()
    );
    let expand = |indices: &Value| -> String {
        indices
            .as_array()
            .unwrap()
            .iter()
            .map(|index| texts[index.as_u64().unwrap() as usize].as_str().unwrap())
            .collect()
    };
    for (plan, expected) in compact["plans"]
        .as_array()
        .unwrap()
        .iter()
        .zip(golden["plans"].as_array().unwrap())
    {
        assert_eq!(expand(&plan["rawPrompt"]), expected["rawPrompt"]);
        let messages: Vec<_> = plan["messages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|message| json!({"role":message["role"], "content":expand(&message["content"])}))
            .collect();
        assert_eq!(json!(messages), expected["messages"]);
    }
}
