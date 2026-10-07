//! Own the two native journeys against the actual local packs, sequentially.
use super::*;

pub(super) fn run(args: &[String]) -> Result<()> {
    require(
        args.len() == 9,
        "demonstration BUNDLE WRITING_PACK CONSULTATION_PACK FIXTURE PROTECTED_ROOT NEW_STUDY SOURCE_SHA256",
    )?;
    require(
        args[2..8].iter().all(|p| Path::new(p).is_absolute()),
        "Use absolute paths",
    )?;
    let bundle = Path::new(&args[2]);
    let study = Path::new(&args[7]);
    require(!study.exists(), "Refuse to replace evidence")?;
    let executable = bundle.join("Contents/MacOS/Bloom");
    let inventory = bundle.join("Contents/Resources/source-files.sha256");
    let source_hash = digest_file(&inventory)?;
    require(source_hash == args[8], "Wrong native source")?;
    let executable_hash = digest_file(&executable)?;
    let fixture = json_file(Path::new(&args[5]))?;
    require(
        fixture["document"]["text"].is_string() && !array(&fixture["examples"])?.is_empty(),
        "Require the authored manuscript and explicit examples",
    )?;
    let mut models = Vec::new();
    for (index, purpose) in [(3, "writing"), (4, "consultation")] {
        let pack = Path::new(&args[index]);
        let path = pack.join("bloom-model.json");
        let manifest = json_file(&path)?;
        require(
            manifest["schema"] == 1
                && manifest["purpose"] == purpose
                && manifest["bits"] == 4
                && manifest["groupSize"] == 32
                && manifest["runtimeRevision"] == "9afc3b55f75a0d41a3d0c11330b9df6a036d24e4",
            "Unsupported local pack",
        )?;
        verify_model(pack, &manifest)?;
        models.push(json!({"purpose":purpose,"directory":pack,"identity":digest_file(&path)?,"manifest":manifest}));
    }
    fs::create_dir(study)?;
    fs::copy(&inventory, study.join("source-files.sha256"))?;
    fs::copy(&args[5], study.join("fixture.json"))?;
    fs::copy(std::env::current_exe()?, study.join("owner"))?;
    write_new(
        &study.join("owner.rs"),
        include_bytes!("../bloom-literary-study.rs"),
    )?;
    write_new(
        &study.join("demonstration-owner.rs"),
        include_bytes!("demonstration.rs"),
    )?;
    let registration = json!({"schema":1,"executable":executable,"executable_sha256":executable_hash,
        "source_inventory_sha256":source_hash,"fixture_sha256":digest_file(&study.join("fixture.json"))?,
        "models":models,"cases":["consultation-capture","consultation-verify","writing-capture","writing-verify"],
        "per_process_deadline_seconds":300,"automatic_retries":false,"network_outbound_denied":true,
        "human_workspace_access_denied":true,"normal_workspace_access_denied":true,
        "foreground_activation":false,"keychain_access":false,
        "scope":"Real-model production voices and writing, native recordings, encrypted relaunch and backup restore; no physical input, OS dialogs, performance or quality qualification"});
    write_json(&study.join("registration.json"), &registration)?;
    let registration_hash = digest_file(&study.join("registration.json"))?;
    let protected = serde_json::to_string(&args[6])?;
    let normal = serde_json::to_string(&format!(
        "{}/Library/Application Support/Bloom",
        std::env::var("HOME")?
    ))?;
    let profile = format!(
        "(version 1) (allow default) (deny network-outbound) (deny file-read* file-write* (subpath {protected})) (deny file-read* file-write* (subpath {normal}))"
    );
    for (kind, model_index) in [("consultation", 1), ("writing", 0)] {
        for action in ["capture", "verify"] {
            let label = format!("{kind}-{action}");
            require(
                digest_file(&executable)? == executable_hash
                    && digest_file(&inventory)? == source_hash,
                "Native producer changed",
            )?;
            let mut command = Command::new("/usr/bin/sandbox-exec");
            command
                .args(["-p", &profile])
                .arg(&executable)
                .args([
                    format!("--{kind}-control-smoke"),
                    action.to_owned(),
                    "--evidence".into(),
                ])
                .arg(study.join(kind));
            if action == "capture" {
                command
                    .arg("--pack")
                    .arg(text(&models[model_index]["directory"])?)
                    .arg("--record-demonstration");
                if kind == "writing" {
                    command.arg("--fixture").arg(study.join("fixture.json"));
                }
            }
            require(
                finish_case(command, study, &label, 300)?,
                "Native journey failed; retain without retry",
            )?;
        }
        let root = study.join(kind);
        let verified = json_file(&root.join("verification.json"))?;
        require(
            verified["status"] == "passed"
                && verified["source_inventory_sha256"] == source_hash
                && native_manifest_matches(
                    &json_file(&root.join("model-manifest.json"))?,
                    &models[model_index]["manifest"],
                ),
            "Native verification or model identity differs",
        )?;
    }
    require(
        digest_file(&executable)? == executable_hash
            && digest_file(&inventory)? == source_hash
            && digest_file(&study.join("fixture.json"))? == registration["fixture_sha256"]
            && digest_file(&study.join("registration.json"))? == registration_hash,
        "Registered inputs changed",
    )?;
    for model in &models {
        let pack = Path::new(text(&model["directory"])?);
        require(
            digest_file(&pack.join("bloom-model.json"))? == model["identity"],
            "Local manifest changed",
        )?;
        verify_model(pack, &model["manifest"])?;
    }
    write_json(
        &study.join("owner-result.json"),
        &json!({"status":"verified",
        "all_children_joined":true,"registered_inputs_unchanged":true,"model_inventories_verified":true,
        "automatic_retries":false,"physical_input_qualified":false,"keychain_dialogs_qualified":false,
        "performance_qualified":false,"literary_quality_qualified":false}),
    )
}

/// Commands are configured by the caller; this owns their common bounded lifetime.
pub(super) fn finish_case(
    mut command: Command,
    study: &Path,
    label: &str,
    deadline: u64,
) -> Result<bool> {
    command
        .env_remove("MLX_METAL_GPU_ARCH")
        .env_remove("MLX_METAL_MAX_OPS")
        .env_remove("MLX_METAL_MAX_MB")
        .env_remove("MTL_CAPTURE_ENABLED")
        .env("MLX_MAX_OPS_PER_BUFFER", "50")
        .env("MLX_MAX_MB_PER_BUFFER", "50")
        .stdin(Stdio::null())
        .stdout(fs::File::create(study.join(format!("{label}.stdout")))?)
        .stderr(fs::File::create(study.join(format!("{label}.stderr")))?)
        .process_group(0);
    let started = Instant::now();
    let mut child = OwnedChild(command.spawn()?);
    println!("{label}: owned process {} started", child.0.id());
    write_json(
        &study.join(format!("{label}-started.json")),
        &json!({"pid":child.0.id(),"process_group":child.0.id(),"deadline_seconds":deadline}),
    )?;
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.0.try_wait()? {
            break status;
        }
        if started.elapsed() >= Duration::from_secs(deadline) {
            timed_out = true;
            child.terminate();
            break child.0.wait()?;
        }
        thread::sleep(Duration::from_millis(100));
    };
    write_json(
        &study.join(format!("{label}-owner.json")),
        &json!({"pid":child.0.id(),
        "child_joined":true,"exit_code":status.code(),"timed_out":timed_out,
        "elapsed_seconds":started.elapsed().as_secs_f64(),"automatic_retries":false}),
    )?;
    println!(
        "{label}: joined, success={}",
        status.success() && !timed_out
    );
    Ok(status.success() && !timed_out)
}

pub(super) fn documents(args: &[String]) -> Result<()> {
    require(
        args.len() == 7,
        "document-authority BUNDLE CONSULTATION_PACK PROTECTED_ROOT NEW_STUDY SOURCE_SHA256",
    )?;
    require(
        args[2..6].iter().all(|p| Path::new(p).is_absolute()),
        "Use absolute paths",
    )?;
    let bundle = Path::new(&args[2]);
    let pack = Path::new(&args[3]);
    let study = Path::new(&args[5]);
    require(!study.exists(), "Refuse to replace evidence")?;
    let executable = bundle.join("Contents/MacOS/Bloom");
    let inventory = bundle.join("Contents/Resources/source-files.sha256");
    let source_hash = digest_file(&inventory)?;
    require(source_hash == args[6], "Wrong native source")?;
    let executable_hash = digest_file(&executable)?;
    let manifest_path = pack.join("bloom-model.json");
    let model = digest_file(&manifest_path)?;
    let manifest = json_file(&manifest_path)?;
    require(
        manifest["schema"] == 1 && manifest["purpose"] == "consultation",
        "Require a local consultation manifest",
    )?;
    verify_model(pack, &manifest)?;
    fs::create_dir(study)?;
    fs::copy(&inventory, study.join("source-files.sha256"))?;
    fs::copy(&manifest_path, study.join("registered-model.json"))?;
    fs::copy(std::env::current_exe()?, study.join("owner"))?;
    write_new(
        &study.join("owner.rs"),
        include_bytes!("../bloom-literary-study.rs"),
    )?;
    write_new(
        &study.join("demonstration-owner.rs"),
        include_bytes!("demonstration.rs"),
    )?;
    let registration = json!({"schema":1,"executable":executable,"executable_sha256":executable_hash,
        "source_inventory_sha256":source_hash,"model":model,"model_directory":pack,
        "cases":["edit","propose","unchanged"],"seed":42,"deadline_seconds":180,
        "automatic_retries":false,"network_outbound_denied":true,"human_workspace_access_denied":true,
        "normal_workspace_access_denied":true,"foreground_activation":false,"keychain_access":false,
        "scope":"Production runner, captured single-document authority, raw responses, mounted native editor, encrypted persistence and Undo; no OS input or Keychain dialogs"});
    write_json(&study.join("registration.json"), &registration)?;
    let registration_hash = digest_file(&study.join("registration.json"))?;
    let protected = serde_json::to_string(&args[4])?;
    let normal = serde_json::to_string(&format!(
        "{}/Library/Application Support/Bloom",
        std::env::var("HOME")?
    ))?;
    let profile = format!(
        "(version 1) (allow default) (deny network-outbound) (deny file-read* file-write* (subpath {protected})) (deny file-read* file-write* (subpath {normal}))"
    );
    let mut failures = 0;
    for case in ["edit", "propose", "unchanged"] {
        require(
            digest_file(&executable)? == executable_hash && digest_file(&inventory)? == source_hash,
            "Native producer changed",
        )?;
        let mut command = Command::new("/usr/bin/sandbox-exec");
        command
            .args(["-p", &profile])
            .arg(&executable)
            .args(["--mlx-smoke", "--pack"])
            .arg(pack)
            .args(["--seed", "42", "--evidence"])
            .arg(study.join(case))
            .arg(format!("--{case}-smoke"));
        let complete = finish_case(command, study, case, 180)?;
        failures += usize::from(!complete);
        if complete {
            let receipt = json_file(&study.join(case).join("receipt.json"))?;
            require(
                receipt["status"] == "passed"
                    && receipt["admitted_identity"] == model
                    && receipt["seed"] == 42
                    && receipt["document_edit"]["mounted_editor"] == true,
                "Native receipt differs from the registered model or editor scope",
            )?;
        }
    }
    require(
        digest_file(&executable)? == executable_hash
            && digest_file(&inventory)? == source_hash
            && digest_file(&manifest_path)? == model
            && digest_file(&study.join("registered-model.json"))? == model
            && digest_file(&study.join("registration.json"))? == registration_hash,
        "Registered inputs changed",
    )?;
    verify_model(pack, &manifest)?;
    write_json(
        &study.join("owner-result.json"),
        &json!({"status":if failures == 0 {"verified"} else {"failed"},
        "failures":failures,"all_children_joined":true,"registered_inputs_unchanged":true,
        "model_inventory_verified":true,"automatic_retries":false,"physical_input_qualified":false,
        "keychain_dialogs_qualified":false}),
    )?;
    require(
        failures == 0,
        "Document cases failed; every independent case retained without retry",
    )
}

pub(super) fn review_documents(study: &Path) -> Result<()> {
    let registration = json_file(&study.join("registration.json"))?;
    let owner = json_file(&study.join("owner-result.json"))?;
    require(
        owner["status"] == "verified"
            && owner["failures"] == 0
            && owner["all_children_joined"] == true
            && owner["registered_inputs_unchanged"] == true
            && owner["model_inventory_verified"] == true,
        "Owner did not complete the registered document workload",
    )?;
    require(
        digest_file(&study.join("source-files.sha256"))? == registration["source_inventory_sha256"]
            && digest_file(&study.join("registered-model.json"))? == registration["model"],
        "Study binding differs",
    )?;
    let mut rows = Vec::new();
    for case in ["edit", "propose", "unchanged"] {
        let child = json_file(&study.join(format!("{case}-owner.json")))?;
        require(
            child["child_joined"] == true && child["exit_code"] == 0 && child["timed_out"] == false,
            "A document child did not complete",
        )?;
        let path = study.join(case).join("receipt.json");
        let receipt = json_file(&path)?;
        require(
            receipt["status"] == "passed"
                && receipt["admitted_identity"] == registration["model"]
                && receipt["seed"] == registration["seed"]
                && !array(&receipt["token_ids"])?.is_empty()
                && receipt["stop_reason"] == "eos",
            "Native model, seed or completed response differs",
        )?;
        let authority = &receipt["authority"];
        let captured = &authority["target"];
        require(
            captured["text"] == "The harbor was quiet."
                && captured["title"] == "Public edit fixture",
            "Captured document differs",
        )?;
        let original = text(&captured["text"])?;
        let context = format!(
            "DOCUMENT Public edit fixture\nID {}\nREVISION {}\n{original}",
            text(&captured["id"])?.to_uppercase(),
            bloom_core::digest(original.as_bytes())
        );
        let request = if case == "unchanged" {
            "Explain the sentence briefly. Do not change any document text. Return edits: [] with your reply."
        } else {
            "In the document, replace quiet with bright. Keep every other character unchanged. Return the actual edit patch."
        };
        let plans = core(
            json!({"op":"compile_consultation","voices":[null],"history":[],
            "instructions":"","context":context,"request":request,"routing":[],"authority":authority}),
        )?;
        require(
            plans[0] == receipt["plan"],
            "Captured context, authority or question does not reproduce the plan",
        )?;
        let decoded = core(json!({"op":"decode_edit_response","text":text(&receipt["text"])?}))?;
        let effect = &receipt["document_edit"];
        require(
            effect["mounted_editor"] == true
                && effect["interactive_ui_acceptance"] == false
                && effect["keychain_acceptance"] == false,
            "Native editor scope differs",
        )?;
        if case == "unchanged" {
            require(
                array(&decoded["edits"])?.is_empty()
                    && authority["mode"] == "Propose"
                    && effect["status"] == "No document changes"
                    && effect["persisted_text"] == captured["text"]
                    && effect["no_changes"] == true
                    && effect["no_proposal"] == true
                    && effect["no_undo_action"] == true,
                "No-change response altered state or reporting",
            )?;
        } else {
            let edits = array(&decoded["edits"])?;
            require(edits.len() == 1, "Require exactly one granted patch")?;
            let applied = core(
                json!({"op":"apply_document_patch","patch":edits[0],"authority":authority,"current":captured}),
            )?;
            require(
                applied["text"] == "The harbor was bright."
                    && effect["persisted_text"] == applied["text"]
                    && effect["status"] == "Document edited"
                    && effect["validated_and_committed"] == true
                    && effect["native_undo_restored_original"] == true
                    && effect["native_undo_persisted_original"] == true
                    && effect["undone_text"] == captured["text"]
                    && effect["proposal_required_acceptance"] == (case == "propose")
                    && authority["mode"] == if case == "propose" { "Propose" } else { "Edit" },
                "Patch, acceptance or persisted Undo differs",
            )?;
        }
        rows.push(json!({"case":case,"raw_receipt_sha256":digest_file(&path)?,"output_tokens":array(&receipt["token_ids"])?.len(),
            "status":effect["status"],"compiled_plan_reproduced":true,"raw_prompt_sha256":bloom_core::digest(text(&receipt["plan"]["rawPrompt"])?.as_bytes())}));
    }
    write_json(
        &study.join("document-review.json"),
        &json!({"status":"verified","rows":rows,
        "source_inventory_sha256":registration["source_inventory_sha256"],"model":registration["model"],
        "scope":"Independent exported-envelope and Rust plan/patch review; native code supplies persistence, preview and Undo observations",
        "independent_decryption":false,"prepared_token_digest_independently_verified":false,
        "physical_input_qualified":false,"keychain_dialogs_qualified":false,"performance_qualified":false}),
    )
}
