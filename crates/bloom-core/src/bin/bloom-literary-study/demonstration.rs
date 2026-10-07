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
                &json!({"pid":child.0.id(),"process_group":child.0.id()}),
            )?;
            let mut timed_out = false;
            let status = loop {
                if let Some(status) = child.0.try_wait()? {
                    break status;
                }
                if started.elapsed() >= Duration::from_secs(300) {
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
            require(
                status.success() && !timed_out,
                "Native journey failed; retain without retry",
            )?;
            println!("{label}: joined successfully");
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
