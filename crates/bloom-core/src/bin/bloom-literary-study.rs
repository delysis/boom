//! Developer-only, source-bound literary comparison through the native app.
//! This binary never opens a user workspace, requests a key or modifies prose.
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    error::Error,
    fs,
    io::{self, Read, Write},
    os::unix::process::CommandExt,
    path::{Component, Path},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
type Result<T> = std::result::Result<T, Box<dyn Error>>;
const LIMIT: u64 = 4 << 20;
const SEEDS: [u64; 3] = [42, 2026, 8675309];
#[path = "bloom-literary-study/memory.rs"]
mod memory;

fn require(condition: bool, message: &str) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(io::Error::other(message).into())
    }
}
fn read(path: &Path) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    require(
        metadata.is_file() && metadata.len() <= LIMIT,
        "Unsafe or oversized study input",
    )?;
    let bytes = fs::read(path)?;
    require(
        bytes.len() as u64 <= LIMIT,
        "Study input grew beyond its bound",
    )?;
    Ok(bytes)
}
fn json_file(path: &Path) -> Result<Value> {
    Ok(serde_json::from_slice(&read(path)?)?)
}
fn digest_file(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(format!("{:x}", digest.finalize()))
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?
        .write_all(bytes)?;
    Ok(())
}
fn write_json(path: &Path, value: &Value) -> Result<()> {
    write_new(path, &serde_json::to_vec_pretty(value)?)
}
fn core(request: Value) -> Result<Value> {
    Ok(bloom_core::execute(serde_json::from_value(request)?)?)
}
fn text(value: &Value) -> Result<&str> {
    value.as_str().ok_or_else(|| "Missing text".into())
}
fn array(value: &Value) -> Result<&[Value]> {
    value
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| "Missing array".into())
}
fn group_matches(a: &Value, b: &Value) -> bool {
    const FIELDS: [&str; 6] = ["id", "fixture", "profile", "seeds", "names", "replayOf"];
    [a, b].iter().all(|value| {
        value.as_object().is_some_and(|object| {
            object.keys().all(|key| FIELDS.contains(&key.as_str()))
                && FIELDS[..5].iter().all(|key| object.contains_key(*key))
        })
    }) && FIELDS.iter().all(|key| a[*key] == b[*key])
}
fn model_identity(manifest: &Value, manifest_hash: &str) -> Result<String> {
    if let Some(identity) = manifest["identity"].as_str() {
        return Ok(identity.to_owned());
    }
    require(
        manifest["schema"] == 1
            && manifest["purpose"] == "writing"
            && manifest["bits"] == 4
            && manifest["groupSize"] == 32
            && manifest["runtimeRevision"] == "9afc3b55f75a0d41a3d0c11330b9df6a036d24e4"
            && manifest["upstreamRepository"] == "google/gemma-4-12B",
        "Unsupported converted model manifest",
    )?;
    Ok(manifest_hash.to_owned())
}
fn native_manifest_matches(native: &Value, registered: &Value) -> bool {
    if registered["identity"].is_string() {
        native["identity"] == registered["identity"] && native["files"] == registered["files"]
    } else {
        native == registered
    }
}
fn prepare(corpus: &Path, destination: &Path) -> Result<()> {
    let mut fixtures = Vec::new();
    for (index, (name, title)) in [
        ("coat-check", "The coat check"),
        ("tide-map", "The tide map"),
    ]
    .into_iter()
    .enumerate()
    {
        let prefix = String::from_utf8(read(&corpus.join(format!("{name}.txt")))?)?;
        let after = String::from_utf8(read(&corpus.join(format!("{name}-after.txt")))?)?;
        let example = String::from_utf8(read(&corpus.join(format!("{name}-example.txt")))?)?;
        require(
            !prefix.trim().is_empty() && !after.is_empty() && !example.trim().is_empty(),
            "Empty authored condition",
        )?;
        let id = format!("ABC00000-0000-4000-8000-{:012}", index + 1);
        let example_id = format!("ABC00000-0000-4000-8001-{:012}", index + 1);
        let document = json!({"id":id,"title":title,"text":format!("{prefix}{after}")});
        let example = json!({"id":example_id,"title":format!("{title}: selected prose example"),"text":example});
        for examples in [vec![], vec![example]] {
            fixtures.push(json!({"document":document,"caretUTF16":prefix.encode_utf16().count(),"examples":examples}));
        }
    }
    write_json(destination, &json!({"fixtures":fixtures,"seeds":SEEDS}))
}
fn verify_model(directory: &Path, manifest: &Value) -> Result<()> {
    let mut names = std::collections::BTreeSet::new();
    for file in array(&manifest["files"])? {
        let name = text(&file["path"])?;
        require(
            !name.is_empty()
                && Path::new(name)
                    .components()
                    .all(|c| matches!(c, Component::Normal(_)))
                && names.insert(name),
            "Unsafe or duplicate manifest path",
        )?;
        let path = directory.join(name);
        require(
            Some(fs::metadata(&path)?.len()) == file["bytes"].as_u64()
                && Some(digest_file(&path)?.as_str()) == file["sha256"].as_str(),
            "Model inventory changed",
        )?;
    }
    require(!names.is_empty(), "Empty model inventory")
}
struct OwnedChild(Child);
impl OwnedChild {
    fn terminate(&mut self) {
        let _ = Command::new("/bin/kill")
            .args(["-KILL", "--"])
            .arg(format!("-{}", self.0.id()))
            .status();
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            self.terminate();
        }
    }
}
fn run(args: &[String]) -> Result<()> {
    require(
        args.len() == 9,
        "run BUNDLE FIXTURES PACK MANIFEST PROTECTED_ROOT NEW_STUDY SOURCE_SHA256",
    )?;
    require(
        args[2..8].iter().all(|p| Path::new(p).is_absolute()),
        "Use absolute paths",
    )?;
    let bundle = Path::new(&args[2]);
    let fixtures = Path::new(&args[3]);
    let pack = Path::new(&args[4]);
    let study = Path::new(&args[7]);
    require(!study.exists(), "Refuse to replace evidence")?;
    let executable = bundle.join("Contents/MacOS/Bloom");
    let inventory = bundle.join("Contents/Resources/source-files.sha256");
    let executable_hash = digest_file(&executable)?;
    let source_hash = digest_file(&inventory)?;
    require(source_hash == args[8], "Wrong native source build")?;
    let fixture = json_file(fixtures)?;
    require(
        array(&fixture["fixtures"])?.len() == 4 && fixture["seeds"] == json!(SEEDS),
        "Use the registered four paired conditions and three seeds",
    )?;
    let plan = core(json!({"op":"writing_evaluation_plan","fixtures":4,"seeds":SEEDS}))?;
    let manifest = json_file(Path::new(&args[5]))?;
    require(
        manifest["purpose"] == "writing",
        "Require a writing manifest",
    )?;
    verify_model(pack, &manifest)?;
    let manifest_hash = digest_file(Path::new(&args[5]))?;
    let model = model_identity(&manifest, &manifest_hash)?;
    fs::create_dir(study)?;
    fs::copy(fixtures, study.join("fixtures.json"))?;
    fs::copy(&inventory, study.join("source-files.sha256"))?;
    fs::copy(&args[5], study.join("registered-model.json"))?;
    fs::copy(std::env::current_exe()?, study.join("owner"))?;
    write_new(
        &study.join("owner.rs"),
        include_bytes!("bloom-literary-study.rs"),
    )?;
    let registration = json!({"schema":1,"executable":executable,"executable_sha256":executable_hash,
        "source_inventory_sha256":source_hash,"fixture_sha256":digest_file(fixtures)?,
        "manifest_sha256":manifest_hash,"model":model,
        "execution_plan":plan,"unique_conditions":36,"replay_conditions":36,
        "profiles":["steady","standard","open"],"seeds":SEEDS,"batch_width":3,"max_tokens_per_row":256,
        "deadline_seconds":900,"automatic_retries":false,"outbound_network_denied":true,
        "human_workspace_access_denied":true,"keychain_access":false,"foreground_activation":false,
        "review_method":"shuffled copies conceal profile, seed and example condition until assessments are written",
        "fixture_authorship":"Codex-authored synthetic prose, separate from Bloom outputs",
        "quality_criteria":["scene continuity","prose and register","purposeful versus stalled repetition","useful alternative routes","author control"],
        "default_changes_planned":false,"human_writer_quality_qualified":false});
    write_json(&study.join("registration.json"), &registration)?;
    let registration_hash = digest_file(&study.join("registration.json"))?;
    let protected = serde_json::to_string(&args[6])?;
    let home = std::env::var("HOME")?;
    let normal_workspace =
        serde_json::to_string(&format!("{home}/Library/Application Support/Bloom"))?;
    let profile = format!(
        "(version 1) (allow default) (deny network-outbound) (deny file-read* file-write* (subpath {protected})) (deny file-read* file-write* (subpath {normal_workspace}))"
    );
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command
        .args(["-p", &profile])
        .arg(&executable)
        .args(["--mlx-smoke", "--batch", "--writing-fixtures"])
        .arg(study.join("fixtures.json"))
        .arg("--pack")
        .arg(pack)
        .arg("--evidence")
        .arg(study.join("evaluation"))
        .env_remove("MLX_METAL_GPU_ARCH")
        .env_remove("MLX_METAL_MAX_OPS")
        .env_remove("MLX_METAL_MAX_MB")
        .env_remove("MTL_CAPTURE_ENABLED")
        .env("MLX_MAX_OPS_PER_BUFFER", "50")
        .env("MLX_MAX_MB_PER_BUFFER", "50")
        .stdin(Stdio::null())
        .stdout(fs::File::create(study.join("execution.stdout"))?)
        .stderr(fs::File::create(study.join("execution.stderr"))?)
        .process_group(0);
    let started = Instant::now();
    let mut child = OwnedChild(command.spawn()?);
    write_json(
        &study.join("started.json"),
        &json!({"pid":child.0.id(),"process_group":child.0.id()}),
    )?;
    println!("Owned literary comparison started: {}", child.0.id());
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.0.try_wait()? {
            break status;
        }
        if started.elapsed() >= Duration::from_secs(900) {
            timed_out = true;
            child.terminate();
            break child.0.wait()?;
        }
        thread::sleep(Duration::from_millis(100));
    };
    write_json(
        &study.join("owner-result.json"),
        &json!({"pid":child.0.id(),"child_joined":true,
        "exit_code":status.code(),"timed_out":timed_out,"elapsed_seconds":started.elapsed().as_secs_f64(),"automatic_retries":false}),
    )?;
    require(
        digest_file(&executable)? == executable_hash
            && digest_file(&inventory)? == source_hash
            && digest_file(&study.join("registration.json"))? == registration_hash
            && digest_file(&study.join("fixtures.json"))? == registration["fixture_sha256"]
            && digest_file(&study.join("registered-model.json"))?
                == registration["manifest_sha256"],
        "Registered inputs changed",
    )?;
    verify_model(pack, &manifest)?;
    write_json(
        &study.join("inputs-after.json"),
        &json!({"registered_inputs_unchanged":true,"model_inventory_verified":true}),
    )?;
    require(
        status.success() && !timed_out,
        "Execution failed; retain this attempt",
    )?;
    println!("Literary execution joined; output verification and quality review remain separate");
    Ok(())
}
fn review(study: &Path) -> Result<()> {
    let registration = json_file(&study.join("registration.json"))?;
    require(
        digest_file(&study.join("fixtures.json"))? == registration["fixture_sha256"]
            && digest_file(&study.join("source-files.sha256"))?
                == registration["source_inventory_sha256"]
            && digest_file(&study.join("registered-model.json"))?
                == registration["manifest_sha256"],
        "Study binding changed",
    )?;
    let owner = json_file(&study.join("owner-result.json"))?;
    require(
        owner["child_joined"] == true
            && owner["exit_code"] == 0
            && owner["timed_out"] == false
            && json_file(&study.join("inputs-after.json"))?["registered_inputs_unchanged"] == true,
        "Owner did not finish",
    )?;
    let root = study.join("evaluation");
    let receipt = json_file(&root.join("evaluation.json"))?;
    let fixtures = json_file(&study.join("fixtures.json"))?;
    let registered_model = json_file(&study.join("registered-model.json"))?;
    let native_model = json_file(&root.join("model-manifest.json"))?;
    require(
        native_manifest_matches(&native_model, &registered_model),
        "Native model manifest differs",
    )?;
    require(
        receipt["status"] == "execution_complete"
            && receipt["admitted_identity"] == registration["model"]
            && receipt["source_inventory_sha256"] == registration["source_inventory_sha256"]
            && receipt["fixture_sha256"] == registration["fixture_sha256"],
        "Native binding differs",
    )?;
    let native_plan = json_file(&root.join("execution-plan.json"))?;
    let planned = array(&registration["execution_plan"])?;
    require(
        array(&native_plan)?.len() == planned.len()
            && array(&native_plan)?
                .iter()
                .zip(planned)
                .all(|(a, b)| group_matches(a, b)),
        "Native plan changed",
    )?;
    let mut failures = 0;
    let mut empty = 0;
    let mut replay_matches = Vec::new();
    let mut attempts = Vec::new();
    for group in array(&registration["execution_plan"])? {
        let names = array(&group["names"])?;
        let fixture_index = group["fixture"].as_u64().ok_or("Missing fixture index")? as usize;
        let fixture = &fixtures["fixtures"][fixture_index];
        let example_texts = array(&fixture["examples"])?
            .iter()
            .map(|e| Ok(text(&e["text"])?.to_owned()))
            .collect::<Result<Vec<_>>>()?;
        let caret = fixture["caretUTF16"].as_u64().ok_or("Missing caret")? as usize;
        let prompt = bloom_core::writing_prompt(
            text(&fixture["document"]["text"])?,
            caret,
            &example_texts,
            usize::MAX,
        )?;
        let mut states = Vec::new();
        for (lane, name) in names.iter().enumerate() {
            let name = text(name)?;
            let trial = json_file(&root.join(format!("{name}.json")))?;
            attempts.push(Value::String(name.into()));
            states.push(trial["state"].clone());
            let state = text(&trial["state"])?;
            require(
                ["generated", "ended_without_prose", "failed", "cancelled"].contains(&state),
                "Missing terminal trial",
            )?;
            if state == "failed" || state == "cancelled" {
                failures += 1;
            }
            if state == "ended_without_prose" {
                empty += 1;
            }
            require(
                trial["fixture"] == group["fixture"]
                    && trial["seed"] == group["seeds"][lane]
                    && trial["batch"]["lane"] == lane
                    && trial["batch"]["seeds"] == group["seeds"],
                "Lost row identity",
            )?;
            if state == "generated" || state == "ended_without_prose" {
                let recipe = &trial["recipe"];
                let expected_sources: Vec<_> = array(&fixture["examples"])?.iter().map(|example| {
                    Ok(json!({"id":example["id"],"title":example["title"],
                        "digest":bloom_core::digest(text(&example["text"])?.as_bytes()),"kind":"writing-example"}))
                }).collect::<Result<_>>()?;
                require(
                    recipe["document"] == fixture["document"]
                        && recipe["caretUTF16"] == fixture["caretUTF16"]
                        && recipe["prompt"] == prompt.prompt
                        && recipe["promptDigest"] == prompt.digest
                        && recipe["omittedPrefixCharacters"] == 0
                        && recipe["model"] == registration["model"]
                        && recipe["sources"] == json!(expected_sources)
                        && recipe["profile"] == group["profile"]
                        && recipe["maxTokens"] == 256,
                    "Captured context or model differs",
                )?;
                let expected: bloom_core::Sampling = serde_json::from_value(core(
                    json!({"op":"sampling","profile":group["profile"]}),
                )?)?;
                let actual: bloom_core::Sampling =
                    serde_json::from_value(recipe["settings"].clone())?;
                require(
                    actual == expected && array(&trial["tokenIDs"])?.len() <= 256,
                    "Sampling or output budget differs",
                )?;
                if group["replayOf"].is_string() {
                    let original_name = name
                        .strip_suffix("-replay")
                        .ok_or("Missing replay suffix")?;
                    let original = json_file(&root.join(format!("{original_name}.json")))?;
                    let matched = [
                        "recipe",
                        "batch",
                        "promptDigest",
                        "promptTokens",
                        "text",
                        "tokenIDs",
                        "stopReason",
                        "stopTokenID",
                    ]
                    .iter()
                    .all(|field| trial[*field] == original[*field]);
                    replay_matches.push(matched);
                }
            } else if group["replayOf"].is_string() {
                replay_matches.push(false);
            }
        }
        let metrics = json_file(&root.join(format!("{}-metrics.json", text(&group["id"])?)))?;
        require(
            group_matches(&metrics["group"], group) && metrics["row_states"] == json!(states),
            "Group ledger differs",
        )?;
        if states
            .iter()
            .all(|s| s == "generated" || s == "ended_without_prose")
        {
            require(
                metrics["metrics"]["width"] == 3
                    && metrics["metrics"]["sharedPromptPrefills"] == 1
                    && !array(&metrics["metrics"]["cacheBatchDimensions"])?.is_empty()
                    && array(&metrics["metrics"]["cacheBatchDimensions"])?
                        .iter()
                        .all(|n| n == 3),
                "Generation was not a shared-prefill batch",
            )?;
        }
    }
    require(
        receipt["attempts"] == json!(attempts)
            && receipt["failures"] == failures
            && receipt["ended_without_prose"] == empty,
        "Lost output or failure",
    )?;
    write_json(
        &study.join("mechanical-review.json"),
        &json!({"status":"verified","attempts":attempts.len(),
        "unique_outputs":36,"replay_outputs":36,"failures":failures,"ended_without_prose":empty,
        "replay_matches":replay_matches,"all_replays_match":replay_matches.iter().all(|m| *m),
        "all_contexts_complete":true,"text_after_caret_excluded":true,"shared_prefill_verified":true,
        "independent_tokenizer_qualified":false,"human_writer_quality_qualified":false}),
    )
}
fn booklet(study: &Path, destination: &Path) -> Result<()> {
    let registration = json_file(&study.join("registration.json"))?;
    let fixtures = json_file(&study.join("fixtures.json"))?;
    require(
        json_file(&study.join("mechanical-review.json"))?["status"] == "verified",
        "Verify mechanical capture first",
    )?;
    require(!destination.exists(), "Refuse to replace reading copies")?;
    fs::create_dir(destination)?;
    let mut reading = String::from(
        "# Continuations for review\n\nSampling labels, seeds and example conditions are concealed. These are unedited Bloom outputs. Score continuity, prose and repetition as 0 (serious defect), 1 (requires repair), or 2 (coherent/effective), and give a concrete reason. Record useful fragments as well as whole-continuation weaknesses. Empty or failed rows remain visible.\n\n",
    );
    let mut key = Vec::new();
    let mut scores = String::from("label,continuity,prose,repetition,observation,author_use\n");
    for scene in 0..2 {
        let fixture = &fixtures["fixtures"][scene * 2];
        let prefix = bloom_core::authored_prefix(
            text(&fixture["document"]["text"])?,
            fixture["caretUTF16"].as_u64().ok_or("Missing caret")? as usize,
        )?;
        reading.push_str(&format!(
            "## {}\n\n{}\n\n",
            text(&fixture["document"]["title"])?,
            prefix
        ));
        let mut rows = Vec::new();
        for group in array(&registration["execution_plan"])? {
            if group["replayOf"].is_string()
                || group["fixture"].as_u64().ok_or("Missing fixture")? as usize / 2 != scene
            {
                continue;
            }
            for name in array(&group["names"])? {
                let name = text(name)?.to_owned();
                rows.push((
                    // A different model must not reuse a previously revealed label key.
                    bloom_core::digest(
                        format!("bloom-literary-blind-v2:{}:{name}", registration["model"])
                            .as_bytes(),
                    ),
                    name,
                ));
            }
        }
        rows.sort();
        for (index, (_, name)) in rows.iter().enumerate() {
            let label = format!("{}-{:02}", if scene == 0 { "A" } else { "B" }, index + 1);
            let trial = json_file(&study.join("evaluation").join(format!("{name}.json")))?;
            reading.push_str(&format!("### {label}\n\n{}\n\n", text(&trial["text"])?));
            if trial["state"] != "generated" {
                reading.push_str(&format!("Retained state: {}.\n\n", text(&trial["state"])?));
            }
            scores.push_str(&format!("{label},,,,,\n"));
            key.push(json!({"label":label,"trial":name,"fixture":trial["fixture"],"seed":trial["seed"],"profile":trial["recipe"]["profile"],"state":trial["state"]}));
        }
    }
    write_new(&destination.join("READING.md"), reading.as_bytes())?;
    write_new(&destination.join("scores.csv"), scores.as_bytes())?;
    write_json(
        &destination.join("REVEAL-AFTER-ASSESSMENT.json"),
        &json!({"assignments":key,"registration_sha256":digest_file(&study.join("registration.json"))?}),
    )
}
fn reference(study: &Path, executable: &Path, tokenizer: &Path) -> Result<()> {
    let registration = json_file(&study.join("registration.json"))?;
    let model = json_file(&study.join("registered-model.json"))?;
    let expected = array(&model["files"])?
        .iter()
        .find(|f| f["path"] == "tokenizer.json")
        .ok_or("Missing tokenizer inventory")?;
    let tokenizer_hash = digest_file(tokenizer)?;
    require(
        Some(tokenizer_hash.as_str()) == expected["sha256"].as_str(),
        "Wrong reference tokenizer",
    )?;
    require(
        json_file(&study.join("mechanical-review.json"))?["all_replays_match"] == true,
        "Verify all replay identities first",
    )?;
    let directory = study.join("tokenizer-reference");
    require(!directory.exists(), "Refuse to replace reference evidence")?;
    fs::create_dir(&directory)?;
    let executable_hash = digest_file(executable)?;
    let mut prompts = std::collections::BTreeSet::new();
    let mut reports = Vec::new();
    for group in array(&registration["execution_plan"])? {
        if group["replayOf"].is_string() {
            continue;
        }
        for name in array(&group["names"])? {
            let name = text(name)?;
            let trial = json_file(&study.join("evaluation").join(format!("{name}.json")))?;
            if trial["state"] != "generated" && trial["state"] != "ended_without_prose" {
                continue;
            }
            let prompt = text(&trial["recipe"]["prompt"])?;
            let prompt_hash = bloom_core::digest(prompt.as_bytes());
            if prompts.insert(prompt_hash.clone()) {
                let path = directory.join(format!("{prompt_hash}.txt"));
                write_new(&path, prompt.as_bytes())?;
                let result = reference_call(
                    executable,
                    tokenizer,
                    "encode",
                    &path,
                    &directory.join(format!("{prompt_hash}-encode")),
                )?;
                require(
                    result["without_special_token_count"] == trial["promptTokens"]
                        && result["without_special_prompt_digest"] == trial["promptDigest"]
                        && result["compiled_writing_comparison"]["matches_checkpoint_postprocessing"]
                            == true
                        && result["compiled_writing_comparison"]["compiled_first_token"] == 2,
                    "Independent prompt encoding differs",
                )?;
            }
            let ids = directory.join(format!("{name}-ids.json"));
            write_json(&ids, &trial["tokenIDs"])?;
            let result = reference_call(
                executable,
                tokenizer,
                "decode",
                &ids,
                &directory.join(format!("{name}-decode")),
            )?;
            require(
                result["text"] == trial["text"]
                    && result["token_count"] == array(&trial["tokenIDs"])?.len(),
                "Independent output decoding differs",
            )?;
            reports.push(json!({"trial":name,"compiled_prompt_sha256":prompt_hash,"raw_decoding_matches":true}));
        }
    }
    require(
        digest_file(executable)? == executable_hash && digest_file(tokenizer)? == tokenizer_hash,
        "Reference inputs changed",
    )?;
    write_json(
        &study.join("tokenizer-review.json"),
        &json!({"status":"verified","reference_executable_sha256":executable_hash,
        "tokenizer_sha256":tokenizer_hash,"unique_prompts":prompts.len(),"original_decodes":reports.len(),
        "canonical_single_bos_verified":true,"replay_coverage":"complete token/text equality checked separately",
        "reports":reports,"quality_qualified":false}),
    )
}
fn reference_call(
    executable: &Path,
    tokenizer: &Path,
    operation: &str,
    input: &Path,
    output: &Path,
) -> Result<Value> {
    let stdout = output.with_extension("json");
    let stderr = output.with_extension("stderr");
    let mut command = Command::new(executable);
    command
        .arg(tokenizer)
        .arg(operation)
        .arg(input)
        .stdin(Stdio::null())
        .stdout(
            fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&stdout)?,
        )
        .stderr(
            fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&stderr)?,
        )
        .process_group(0);
    let mut child = OwnedChild(command.spawn()?);
    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.0.try_wait()? {
            break status;
        }
        if started.elapsed() >= Duration::from_secs(30) {
            child.terminate();
            return Err("Reference process deadline; failed evidence retained".into());
        }
        thread::sleep(Duration::from_millis(20));
    };
    require(
        status.success(),
        "Independent tokenizer failed; retain evidence",
    )?;
    json_file(&stdout)
}

fn snapshot_inventory(pack: &Path, upstream: &Path, destination: &Path) -> Result<()> {
    let metadata = json_file(upstream)?;
    let id = text(&metadata["id"])?;
    let revision = text(&metadata["sha"])?;
    require(
        id == "google/gemma-4-12B" && revision.len() == 40,
        "Require official base metadata",
    )?;
    let mut files = Vec::new();
    for entry in array(&metadata["siblings"])? {
        let name = text(&entry["rfilename"])?;
        require(
            Path::new(name)
                .components()
                .all(|c| matches!(c, Component::Normal(_))),
            "Unsafe upstream file",
        )?;
        if name == ".gitattributes" {
            continue;
        }
        let path = pack.join(name);
        let bytes = fs::metadata(&path)?.len();
        let digest = digest_file(&path)?;
        require(
            entry["size"].as_u64() == Some(bytes),
            "Cached upstream file size differs",
        )?;
        if let Some(lfs) = entry.get("lfs") {
            require(
                lfs["sha256"] == digest && lfs["size"].as_u64() == Some(bytes),
                "Cached LFS file differs from official pinned metadata",
            )?;
        } else {
            let blob = Command::new("git")
                .args(["hash-object", "--no-filters"])
                .arg(&path)
                .output()?;
            require(
                blob.status.success()
                    && String::from_utf8(blob.stdout)?.trim() == text(&entry["blobId"])?,
                "Cached Git blob differs from official pinned metadata",
            )?;
        }
        files.push(
            json!({"path":name,"bytes":bytes,"sha256":digest,"upstream_blob_id":entry["blobId"]}),
        );
    }
    require(
        files.iter().any(|f| f["path"] == "model.safetensors"),
        "Missing official weights",
    )?;
    write_json(
        destination,
        &json!({"identity":format!("{id}@{revision}"),"purpose":"writing",
        "upstream_metadata_sha256":digest_file(upstream)?,"files":files,
        "conversionProvenance":"Official BF16 checkpoint; upstream LFS SHA256 verified, no conversion."}),
    )
}

fn fidelity(args: &[String]) -> Result<()> {
    require(
        args.len() == 9,
        "fidelity BUILDER FIXTURE PACK MANIFEST PROTECTED_ROOT NEW_STUDY MODEL_IDENTITY",
    )?;
    require(
        args[2..8].iter().all(|p| Path::new(p).is_absolute()),
        "Use absolute paths",
    )?;
    let executable = Path::new(&args[2]);
    let fixture = Path::new(&args[3]);
    let pack = Path::new(&args[4]);
    let manifest_path = Path::new(&args[5]);
    let study = Path::new(&args[7]);
    let captured = json_file(fixture)?;
    require(
        captured["promptTokens"] == 659
            && captured["tokenIDs"] == json!([236913, 3771, 625, 5889, 236789])
            && captured["stopTokenID"] == 1,
        "Require the captured malformed contraction",
    )?;
    let manifest = json_file(manifest_path)?;
    require(
        manifest["identity"] == args[8] && manifest["purpose"] == "writing",
        "Wrong model identity",
    )?;
    verify_model(pack, &manifest)?;
    fs::create_dir(study)?;
    fs::copy(fixture, study.join("fixture.json"))?;
    fs::copy(manifest_path, study.join("registered-model.json"))?;
    fs::copy(std::env::current_exe()?, study.join("owner"))?;
    write_new(
        &study.join("owner.rs"),
        include_bytes!("bloom-literary-study.rs"),
    )?;
    let plan = json!({"pack":pack,"model":args[8],"fixture":study.join("fixture.json"),
        "fixtureSHA256":digest_file(fixture)?,"output":study.join("native")});
    write_json(&study.join("plan.json"), &plan)?;
    let registration = json!({"schema":1,"executable":executable,"executable_sha256":digest_file(executable)?,
        "fixture_sha256":digest_file(fixture)?,"manifest_sha256":digest_file(manifest_path)?,
        "plan_sha256":digest_file(&study.join("plan.json"))?,"model":args[8],"process_budget_bytes":24_u64<<30,
        "deadline_seconds":300,"automatic_retries":false,"outbound_network_denied":true,
        "human_workspace_access_denied":true,"keychain_access":false,"foreground_activation":false,
        "scope":"Same Swift architecture, teacher-forced raw logits; not independent architecture or product admission qualification"});
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
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command
        .args(["-p", &profile])
        .arg(executable)
        .arg("--base-fidelity")
        .arg(study.join("plan.json"))
        .env_remove("MLX_METAL_GPU_ARCH")
        .env_remove("MLX_METAL_MAX_OPS")
        .env_remove("MLX_METAL_MAX_MB")
        .env_remove("MTL_CAPTURE_ENABLED")
        .env("MLX_MAX_OPS_PER_BUFFER", "50")
        .env("MLX_MAX_MB_PER_BUFFER", "50")
        .stdin(Stdio::null())
        .stdout(fs::File::create(study.join("execution.stdout"))?)
        .stderr(fs::File::create(study.join("execution.stderr"))?)
        .process_group(0);
    let started = Instant::now();
    let mut child = OwnedChild(command.spawn()?);
    write_json(
        &study.join("started.json"),
        &json!({"pid":child.0.id(),"process_group":child.0.id()}),
    )?;
    println!("Owned precision screen started: {}", child.0.id());
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
        &study.join("owner-result.json"),
        &json!({"pid":child.0.id(),"child_joined":true,
        "exit_code":status.code(),"timed_out":timed_out,"elapsed_seconds":started.elapsed().as_secs_f64(),"automatic_retries":false}),
    )?;
    require(
        digest_file(executable)? == registration["executable_sha256"]
            && digest_file(&study.join("fixture.json"))? == registration["fixture_sha256"]
            && digest_file(&study.join("registered-model.json"))?
                == registration["manifest_sha256"]
            && digest_file(&study.join("plan.json"))? == registration["plan_sha256"]
            && digest_file(&study.join("registration.json"))? == registration_hash,
        "Registered inputs changed",
    )?;
    verify_model(pack, &manifest)?;
    write_json(
        &study.join("inputs-after.json"),
        &json!({"registered_inputs_unchanged":true,"model_inventory_verified":true}),
    )?;
    require(
        status.success() && !timed_out,
        "Precision screen failed; retain this attempt",
    )
}

fn converted_inventory(
    pack: &Path,
    expected: &str,
    upstream: &Path,
    destination: &Path,
) -> Result<()> {
    let path = pack.join("bloom-model.json");
    require(
        digest_file(&path)? == expected,
        "Converted manifest differs from the signed catalog",
    )?;
    let manifest = json_file(&path)?;
    let official = json_file(upstream)?;
    require(
        manifest["purpose"] == "writing"
            && manifest["bits"] == 4
            && manifest["groupSize"] == 32
            && manifest["runtimeRevision"] == "9afc3b55f75a0d41a3d0c11330b9df6a036d24e4"
            && official["identity"]
                == format!(
                    "{}@{}",
                    text(&manifest["upstreamRepository"])?,
                    text(&manifest["upstreamRevision"])?
                ),
        "Wrong converted checkpoint lineage",
    )?;
    let originals = array(&official["files"])?;
    for file in array(&manifest["upstreamFiles"])? {
        require(
            originals.iter().any(|f| {
                f["path"] == file["path"]
                    && f["bytes"] == file["bytes"]
                    && f["sha256"] == file["sha256"]
            }),
            "Converted pack declares different upstream bytes",
        )?;
    }
    verify_model(pack, &manifest)?;
    let mut files = array(&manifest["files"])?.to_vec();
    files.push(
        json!({"path":"bloom-model.json","bytes":fs::metadata(&path)?.len(),"sha256":expected}),
    );
    write_json(
        destination,
        &json!({"identity":format!("bloom/writing@{expected}"),"purpose":"writing","files":files,
        "upstream":official["identity"],"upstream_metadata_sha256":digest_file(upstream)?,
        "conversionProvenance":"Existing catalog-pinned local affine 4-bit/group-32 conversion; declared upstream bytes matched to verified official snapshot."}),
    )
}

fn logit_metrics(bytes: &[u8]) -> Result<Value> {
    require(bytes.len() == 262_144 * 4, "Wrong vocabulary-vector length")?;
    let values: Vec<_> = bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect();
    require(
        values.iter().all(|x| x.is_finite()),
        "Nonfinite vocabulary logits",
    )?;
    let maximum = values.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let total: f64 = values
        .iter()
        .map(|&x| (f64::from(x) - f64::from(maximum)).exp())
        .sum();
    let mut tokens = Vec::new();
    for (id, label) in [(1, "EOS"), (236745, "literal t")] {
        let logit = values[id];
        tokens.push(json!({"id":id,"label":label,"logit":logit,
            "rank":1+values.iter().filter(|&&x| x > logit).count(),
            "unfiltered_probability":(f64::from(logit)-f64::from(maximum)).exp()/total}));
    }
    Ok(
        json!({"vocabulary":values.len(),"tokens":tokens,"probability_scope":"Unfiltered softmax, not Standard's filtered sampling probability"}),
    )
}

fn fidelity_review(study: &Path) -> Result<()> {
    let registration = json_file(&study.join("registration.json"))?;
    let owner = json_file(&study.join("owner-result.json"))?;
    require(
        owner["child_joined"] == true && owner["exit_code"] == 0 && owner["timed_out"] == false,
        "Screen did not complete",
    )?;
    require(
        json_file(&study.join("inputs-after.json"))?["model_inventory_verified"] == true
            && digest_file(&study.join("fixture.json"))? == registration["fixture_sha256"]
            && digest_file(&study.join("registered-model.json"))?
                == registration["manifest_sha256"]
            && digest_file(&study.join("plan.json"))? == registration["plan_sha256"],
        "Input binding differs",
    )?;
    let report = json_file(&study.join("native/report.json"))?;
    require(
        report["status"] == "complete" && report["model"] == registration["model"],
        "Native screen incomplete",
    )?;
    let mut observations = Vec::new();
    for (name, count) in [("prefix", 659), ("after-apostrophe", 664)] {
        let path = study.join("native").join(format!("{name}.f32"));
        let metadata = json_file(&study.join("native").join(format!("{name}.json")))?;
        require(
            digest_file(&path)? == metadata["logits_sha256"] && metadata["input_tokens"] == count,
            "Logit identity differs",
        )?;
        for field in ["current_footprint_bytes", "kernel_peak_footprint_bytes"] {
            require(
                metadata["memory"][field]
                    .as_u64()
                    .is_some_and(|x| x <= 24_u64 << 30),
                "Process budget exceeded",
            )?;
        }
        observations.push(json!({"name":name,"metrics":logit_metrics(&read(&path)?)?,"memory":metadata["memory"]}));
    }
    write_json(
        &study.join("logit-review.json"),
        &json!({"status":"verified","model":registration["model"],
        "observations":observations,"independent_architecture_qualified":false,"literary_quality_qualified":false}),
    )
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("prepare") if args.len() == 4 => prepare(Path::new(&args[2]), Path::new(&args[3])),
        Some("run") => run(&args),
        Some("memory") => memory::run(&args),
        Some("memory-review") if args.len() == 3 => memory::review(Path::new(&args[2])),
        Some("fidelity") => fidelity(&args),
        Some("converted-inventory") if args.len() == 6 => converted_inventory(
            Path::new(&args[2]),
            &args[3],
            Path::new(&args[4]),
            Path::new(&args[5]),
        ),
        Some("fidelity-review") if args.len() == 3 => fidelity_review(Path::new(&args[2])),
        Some("snapshot-inventory") if args.len() == 5 => snapshot_inventory(
            Path::new(&args[2]),
            Path::new(&args[3]),
            Path::new(&args[4]),
        ),
        Some("review") if args.len() == 3 => review(Path::new(&args[2])),
        Some("booklet") if args.len() == 4 => booklet(Path::new(&args[2]), Path::new(&args[3])),
        Some("reference")
            if args.len() == 5 && args[2..].iter().all(|p| Path::new(p).is_absolute()) =>
        {
            reference(
                Path::new(&args[2]),
                Path::new(&args[3]),
                Path::new(&args[4]),
            )
        }
        _ => Err(
            "Use prepare CORPUS NEW_FIXTURE, run, review STUDY, or booklet STUDY NEW_DIRECTORY"
                .into(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn converted_manifest_requires_full_match_and_uses_its_digest_as_identity() {
        let manifest = json!({"schema":1,"purpose":"writing","bits":4,"groupSize":32,
            "runtimeRevision":"9afc3b55f75a0d41a3d0c11330b9df6a036d24e4","upstreamRepository":"google/gemma-4-12B"});
        assert_eq!(
            model_identity(&manifest, "captured-digest").expect("converted identity"),
            "captured-digest"
        );
        let mut changed = manifest.clone();
        changed["groupSize"] = json!(64);
        assert!(!native_manifest_matches(&changed, &manifest));
        assert!(model_identity(&changed, "captured-digest").is_err());
        assert!(model_identity(&json!({}), "captured-digest").is_err());
    }
    #[test]
    fn logit_reader_rejects_truncation_and_nonfinite_values() {
        assert!(logit_metrics(&[0; 4]).is_err());
        let mut bytes = vec![0; 262_144 * 4];
        let metrics = logit_metrics(&bytes).expect("finite logits");
        assert_eq!(metrics["tokens"][0]["rank"], 1);
        assert_eq!(
            metrics["tokens"][0]["unfiltered_probability"],
            1.0 / 262_144.0
        );
        bytes[..4].copy_from_slice(&f32::NAN.to_le_bytes());
        assert!(logit_metrics(&bytes).is_err());
    }
    #[test]
    fn absent_optional_lineage_matches_null_but_required_identity_never_does() {
        let a = json!({"id":"g","fixture":0,"profile":"standard","seeds":[42],"names":["a"],"replayOf":null});
        let mut b = a.clone();
        b.as_object_mut().expect("object").remove("replayOf");
        assert!(group_matches(&a, &b));
        b["replayOf"] = json!("another-group");
        assert!(!group_matches(&a, &b));
        b = a.clone();
        b.as_object_mut().expect("object").remove("seeds");
        assert!(!group_matches(&a, &b));
        b = a.clone();
        b["seeds"] = json!([2026]);
        assert!(!group_matches(&a, &b));
        b = a.clone();
        b["extra"] = json!(true);
        assert!(!group_matches(&a, &b));
    }
}
