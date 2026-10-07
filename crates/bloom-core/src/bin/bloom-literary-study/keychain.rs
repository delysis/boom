//! Real, noninteractive Keychain qualification through two signed native builds.
use super::*;

pub(super) fn run(args: &[String]) -> Result<()> {
    require(
        args.len() == 7,
        "keychain AUTHOR_BUNDLE CHAT_BUNDLE PROTECTED_ROOT NEW_STUDY SOURCE_SHA256",
    )?;
    require(
        args[2..6].iter().all(|p| Path::new(p).is_absolute()),
        "Use absolute paths",
    )?;
    let study = Path::new(&args[5]);
    require(!study.exists(), "Refuse to replace evidence")?;
    let mut builds = Vec::new();
    for path in [&args[2], &args[3]] {
        let bundle = Path::new(path);
        let executable = bundle.join("Contents/MacOS/Bloom");
        let inventory = bundle.join("Contents/Resources/source-files.sha256");
        require(digest_file(&inventory)? == args[6], "Wrong native source")?;
        let verified = Command::new("/usr/bin/codesign")
            .args(["--verify", "--deep", "--strict"])
            .arg(bundle)
            .output()?;
        require(verified.status.success(), "Invalid bundle signature")?;
        let designated = Command::new("/usr/bin/codesign")
            .args(["-dr", "-"])
            .arg(bundle)
            .output()?;
        require(
            designated.status.success(),
            "Missing designated requirement",
        )?;
        let requirement_output = String::from_utf8(designated.stdout)?;
        let requirement = requirement_output
            .lines()
            .find(|line| line.starts_with("designated =>"))
            .ok_or("Missing designated requirement expression")?;
        builds.push(json!({"bundle":bundle,"executable":executable,
            "executable_sha256":digest_file(&executable)?,"source_inventory_sha256":args[6],
            "designated_requirement":requirement}));
    }
    require(
        builds[0]["designated_requirement"] == builds[1]["designated_requirement"]
            && builds[0]["executable_sha256"] != builds[1]["executable_sha256"],
        "Require different binaries sharing one designated requirement",
    )?;
    fs::create_dir(study)?;
    fs::copy(std::env::current_exe()?, study.join("owner"))?;
    write_new(
        &study.join("keychain-owner.rs"),
        include_bytes!("keychain.rs"),
    )?;
    let id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let registration = json!({"schema":1,"qualification_id":id,"builds":builds,
        "cases":["create","reopen","rebuilt-reopen","failures","cleanup"],
        "per_process_deadline_seconds":60,"automatic_retries":false,
        "network_outbound_denied":true,"human_workspace_access_denied":true,
        "keychain_scope":"Disposable qualification item only; process-local UI disabled",
        "keychain_dialogs_qualified":false,"physical_denial_qualified":false});
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
    write_new(&study.join("sandbox.sb"), profile.as_bytes())?;
    let mut passed = true;
    let mut results = Vec::new();
    for (label, action, index) in [
        ("create", "create", 0),
        ("reopen", "reopen", 0),
        ("rebuilt-reopen", "reopen", 1),
        ("failures", "failures", 1),
        ("cleanup", "cleanup", 1),
    ] {
        if !passed && action != "cleanup" {
            continue;
        }
        let executable = Path::new(text(&builds[index]["executable"])?);
        require(
            digest_file(executable)? == builds[index]["executable_sha256"],
            "Producer changed",
        )?;
        let mut command = Command::new("/usr/bin/sandbox-exec");
        command
            .args(["-p", &profile])
            .arg(executable)
            .args([
                "--keychain-smoke",
                action,
                "--qualification-id",
                &id,
                "--evidence",
            ])
            .arg(study.join(label));
        let finished = demonstration::finish_case(command, study, label, 60)?;
        passed &= finished;
        if study.join(label).join("receipt.json").exists() {
            let receipt = json_file(&study.join(label).join("receipt.json"))?;
            passed &= receipt["status"] == "passed"
                && receipt["qualification_id"] == id
                && receipt["source_inventory_sha256"] == args[6]
                && receipt["production_session_lookups"] == 0
                && receipt["interaction_allowed"] == false
                && receipt["keychain_dialogs_qualified"] == false
                && receipt["physical_denial_qualified"] == false;
            results.push(json!({"case":label,"build":index,"receipt":receipt}));
        } else {
            passed = false;
        }
    }
    if passed {
        let initial = &results[0]["receipt"];
        for observation in &results[..3] {
            let receipt = &observation["receipt"];
            require(
                receipt["consumers"] == 16
                    && receipt["session_lookups"] == 1
                    && receipt["ciphertext"] == initial["ciphertext"]
                    && receipt["document_revision"] == initial["document_revision"],
                "Consumers or relaunch changed ciphertext",
            )?;
        }
        let failures = array(&results[3]["receipt"]["failures"])?;
        require(failures.len() == 3, "Missing failure cases")?;
        for failure in failures {
            require(
                failure["session_lookups"] == 1
                    && failure["ciphertext_unchanged"] == true
                    && failure["replacement_key_created"] == false,
                "Failure handling differs",
            )?;
        }
        require(
            results[4]["receipt"]["item_absent"] == true,
            "Disposable item not removed",
        )?;
    }
    require(
        digest_file(&study.join("registration.json"))? == registration_hash,
        "Registration changed",
    )?;
    for build in &builds {
        require(
            digest_file(Path::new(text(&build["executable"])?))? == build["executable_sha256"]
                && digest_file(
                    &Path::new(text(&build["bundle"])?)
                        .join("Contents/Resources/source-files.sha256"),
                )? == args[6],
            "Build changed",
        )?;
    }
    write_json(
        &study.join("owner-result.json"),
        &json!({"status":if passed {"verified"} else {"failed"},
        "cases":results,"all_started_children_joined":true,"automatic_retries":false,
        "keychain_dialogs_qualified":false,"physical_denial_qualified":false,
        "scope":"Real Keychain item creation, concurrent consumers, same-binary and changed-binary relaunch, missing/malformed/wrong keys, cleanup; no interactive authorization"}),
    )?;
    require(
        passed,
        "Real Keychain qualification failed; evidence retained, no retry",
    )
}
