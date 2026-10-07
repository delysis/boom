//! Own and review a public-fixture MLX prefill profile. No vault or network.
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::{
    collections::BTreeMap,
    error::Error,
    fs::{self, File},
    io::{self, Read},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
type Result<T> = std::result::Result<T, Box<dyn Error>>;
const MODEL: &str =
    "mlx-community/gemma-4-12B-it-qat-4bit@e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6";
const PROTECTED: &str = "/Users/george/Documents/Codex/2026-10-04/hi-sol-6-1-new-model/work/editions-native-author-check/workspace";
fn require(ok: bool, message: &str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(io::Error::other(message).into())
    }
}
fn text(value: &Value) -> Result<&str> {
    value
        .as_str()
        .ok_or_else(|| io::Error::other("Missing string").into())
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn hash(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut state = Sha256::new();
    let mut buffer = [0; 65_536];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        state.update(&buffer[..n]);
    }
    Ok(format!("{:x}", state.finalize()))
}
fn read(path: &Path) -> Result<Value> {
    let m = fs::symlink_metadata(path)?;
    require(m.is_file() && m.len() <= 8_388_608, "Unexpected JSON file")?;
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}
fn write(path: &Path, value: &Value) -> Result<()> {
    use std::io::Write;
    let mut file = File::options().write(true).create_new(true).open(path)?;
    file.write_all(&serde_json::to_vec_pretty(value)?)?;
    Ok(())
}
fn verify_pack(pack: &Path, manifest: &Value) -> Result<()> {
    require(
        manifest["identity"] == MODEL && manifest["purpose"] == "consultation",
        "Require the pinned public consultation checkpoint",
    )?;
    let files = manifest["files"]
        .as_array()
        .ok_or_else(|| io::Error::other("Missing model inventory"))?;
    require(!files.is_empty() && files.len() <= 100, "Invalid inventory")?;
    for entry in files {
        let name = text(&entry["path"])?;
        require(
            Path::new(name).components().count() == 1 && !name.starts_with('.'),
            "Invalid model file name",
        )?;
        let path = pack.join(name);
        require(
            fs::metadata(&path)?.len()
                == entry["bytes"]
                    .as_u64()
                    .ok_or_else(|| io::Error::other("Missing length"))?
                && hash(&path)? == text(&entry["sha256"])?,
            "Model inventory differs",
        )?;
    }
    Ok(())
}
struct Owner {
    child: Child,
    joined: bool,
}
impl Owner {
    fn stop(&mut self) -> Result<std::process::ExitStatus> {
        // Only the process group created by this owner; no name-based killing.
        let status = Command::new("/bin/kill")
            .args(["-KILL", "--", &format!("-{}", self.child.id())])
            .status()?;
        if !status.success() {
            let _ = self.child.kill();
        }
        let status = self.child.wait()?;
        self.joined = true;
        Ok(status)
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        if !self.joined {
            let _ = self.stop();
        }
    }
}
fn run(args: &[String]) -> Result<()> {
    require(
        cfg!(target_os = "macos") && args.len() == 7,
        "run ABS_PACK ABS_FIXTURE ABS_MANIFEST ABS_BUILDER NEW_ABS_EVIDENCE",
    )?;
    require(
        args[2..]
            .iter()
            .all(|v| Path::new(v).is_absolute() && !Path::new(v).starts_with(PROTECTED)),
        "Require owned absolute paths",
    )?;
    let pack = Path::new(&args[2]);
    let fixture_path = Path::new(&args[3]);
    let manifest_path = Path::new(&args[4]);
    let builder = Path::new(&args[5]);
    let root = Path::new(&args[6]);
    require(
        !root.exists() && builder.is_file(),
        "Require fresh evidence and native developer executable",
    )?;
    let manifest = read(manifest_path)?;
    let fixture = read(fixture_path)?;
    require(
        fixture["model"] == MODEL && fixture["outputs"][0]["prompt_tokens"] == 4096,
        "Require a captured public 4K consultation",
    )?;
    verify_pack(pack, &manifest)?;
    fs::create_dir(root)?;
    fs::copy(fixture_path, root.join("fixture.json"))?;
    fs::copy(manifest_path, root.join("model-manifest.json"))?;
    let plan_path = root.join("plan.json");
    let plan = json!({"pack":pack,"fixture":root.join("fixture.json"),"fixtureSHA256":hash(fixture_path)?,
        "model":MODEL,"output":root.join("native")});
    write(&plan_path, &plan)?;
    let registration = json!({"model":MODEL,"builder":builder,"builder_sha256":hash(builder)?,
        "plan_sha256":hash(&plan_path)?,"fixture_sha256":hash(fixture_path)?,"manifest_sha256":hash(manifest_path)?,
        "order":["baseline","profile","profile","baseline"],"input_tokens":4096,"prefill_tokens":512,
        "environment":{"MLX_METAL_MAX_OPS":"50","MLX_METAL_MAX_MB":"50","HF_HUB_OFFLINE":"1","MLX_METAL_GPU_ARCH":"removed","MTL_CAPTURE_ENABLED":"removed"},
        "deadline_seconds":300,"network_outbound_denied":true,"protected_workspace_denied":true,
        "scope":"owned public-fixture synchronized operation-group attribution; no product gate"});
    write(&root.join("registration.json"), &registration)?;
    let profile = format!(
        "(version 1) (allow default) (deny network-outbound) (deny file-read* file-write* (subpath \"{PROTECTED}\"))"
    );
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command
        .args(["-p", &profile])
        .arg(builder)
        .arg("--prefill-profile")
        .arg(&plan_path)
        .env("MLX_METAL_MAX_OPS", "50")
        .env("MLX_METAL_MAX_MB", "50")
        .env("HF_HUB_OFFLINE", "1")
        .env_remove("MLX_METAL_GPU_ARCH")
        .env_remove("MTL_CAPTURE_ENABLED")
        .stdin(Stdio::null())
        .stdout(File::create(root.join("native.stdout"))?)
        .stderr(File::create(root.join("native.stderr"))?);
    #[cfg(unix)]
    command.process_group(0);
    let mut owner = Owner {
        child: command.spawn()?,
        joined: false,
    };
    write(
        &root.join("owner.json"),
        &json!({"pid":owner.child.id(),"process_group":owner.child.id()}),
    )?;
    let started = Instant::now();
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = owner.child.try_wait()? {
            owner.joined = true;
            break status;
        }
        if started.elapsed() > Duration::from_secs(300) {
            timed_out = true;
            break owner.stop()?;
        }
        thread::sleep(Duration::from_millis(100));
    };
    let unchanged = registration["builder_sha256"] == hash(builder)?
        && registration["plan_sha256"] == hash(&plan_path)?
        && registration["fixture_sha256"] == hash(&root.join("fixture.json"))?
        && registration["manifest_sha256"] == hash(&root.join("model-manifest.json"))?;
    let pack_check = verify_pack(pack, &manifest);
    write(
        &root.join("driver-complete.json"),
        &json!({"exit_code":status.code(),"child_joined":owner.joined,
        "timed_out":timed_out,"elapsed_seconds":started.elapsed().as_secs_f64(),
        "registered_inputs_unchanged":unchanged,"pack_unchanged":pack_check.is_ok()}),
    )?;
    pack_check?;
    require(
        status.success() && !timed_out && unchanged,
        "Profile failed; retained evidence, no retry",
    )?;
    println!("Owned native profile completed: {}", root.display());
    Ok(())
}
fn positive(value: &Value, allow_zero: bool) -> Result<f64> {
    value
        .as_f64()
        .filter(|v| v.is_finite() && if allow_zero { *v >= 0.0 } else { *v > 0.0 })
        .ok_or_else(|| io::Error::other("Invalid timing").into())
}
fn review(root: &Path) -> Result<()> {
    let registration = read(&root.join("registration.json"))?;
    let done = read(&root.join("driver-complete.json"))?;
    require(
        done["exit_code"] == 0
            && done["child_joined"] == true
            && done["timed_out"] == false
            && done["registered_inputs_unchanged"] == true
            && done["pack_unchanged"] == true,
        "Execution binding failed",
    )?;
    require(
        registration["plan_sha256"] == hash(&root.join("plan.json"))?
            && registration["fixture_sha256"] == hash(&root.join("fixture.json"))?
            && registration["manifest_sha256"] == hash(&root.join("model-manifest.json"))?,
        "Inputs differ",
    )?;
    let native = read(&root.join("native/observations.json"))?;
    require(
        native["status"] == "complete"
            && native["model"] == MODEL
            && native["input_tokens"] == 4096
            && native["prefill_tokens"] == 512,
        "Incomplete native observations",
    )?;
    let fixture = read(&root.join("fixture.json"))?;
    let ids = read(&root.join("native/input-token-ids.json"))?;
    require(
        ids.as_array().is_some_and(|a| a.len() == 4096)
            && digest(&serde_json::to_vec(&ids)?) == text(&fixture["outputs"][0]["prompt_digest"])?,
        "Captured tokens differ",
    )?;
    let trials = native["trials"]
        .as_array()
        .ok_or_else(|| io::Error::other("Missing trials"))?;
    require(trials.len() == 4, "Missing scheduled trials")?;
    let mut reference: Option<Vec<u8>> = None;
    let mut summaries = Vec::new();
    for (index, trial) in trials.iter().enumerate() {
        let arm = text(&registration["order"][index])?;
        require(
            trial["trial"] == index
                && trial["arm"] == arm
                && trial["finite"] == true
                && trial["logits_shape"] == json!([1, 262144]),
            "Native order or output differs",
        )?;
        let filename = text(&trial["logits_file"])?;
        require(
            filename == format!("trial-{index}-{arm}.f32le"),
            "Unexpected output path",
        )?;
        let bytes = fs::read(root.join("native").join(filename))?;
        require(
            bytes.len() == 262144 * 4
                && digest(&bytes) == text(&trial["logits_sha256"])?
                && bytes.chunks_exact(4).all(|b| {
                    <[u8; 4]>::try_from(b).is_ok_and(|v| f32::from_le_bytes(v).is_finite())
                }),
            "Saved logits failed verification",
        )?;
        if let Some(reference) = &reference {
            require(
                reference == &bytes,
                "Instrumentation changed complete logits",
            )?;
        } else {
            reference = Some(bytes);
        }
        let total = positive(&trial["seconds"], false)?;
        let rows = trial["observations"]
            .as_array()
            .ok_or_else(|| io::Error::other("Missing operation observations"))?;
        require(
            (arm == "profile") != rows.is_empty(),
            "Missing profile or unexpected baseline instrumentation",
        )?;
        let mut groups = BTreeMap::<String, (usize, f64, f64)>::new();
        for row in rows {
            let module = text(&row["module"])?;
            require(
                native["modules"]
                    .as_array()
                    .is_some_and(|a| a.iter().any(|v| v == module)),
                "Unknown measured module",
            )?;
            let group = if module.contains(".mlp.") {
                "mlp"
            } else if module.ends_with(".o_proj") {
                "attention_output"
            } else if module.contains(".self_attn.") {
                "attention_qkv"
            } else {
                "other_projection"
            };
            let entry = groups.entry(group.to_owned()).or_default();
            entry.0 += 1;
            entry.1 += positive(&row["projection_seconds"], false)?;
            entry.2 += positive(&row["input_settlement_seconds"], true)?;
        }
        let attributed = groups.values().map(|(_, a, b)| a + b).sum::<f64>();
        require(
            attributed <= total,
            "Attribution exceeds full profile duration",
        )?;
        summaries.push(
            json!({"trial":index,"arm":arm,"seconds":total,"groups":groups,
            "unattributed_seconds":total-attributed,"operation_observations":rows.len()}),
        );
    }
    write(
        &root.join("independent-review.json"),
        &json!({"status":"passed","complete_logit_vectors_verified":4,
        "exact_instrumented_logits":true,"trials":summaries,
        "scope":"full saved output equality and synchronized operation-group attribution; not kernel or app performance"}),
    )?;
    println!("Four complete logit vectors and operation-group observations verified.");
    Ok(())
}
fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("run") => run(&args),
        Some("review") if args.len() == 3 && Path::new(&args[2]).is_absolute() => review(&PathBuf::from(&args[2])),
        _ => Err(io::Error::other("Use run ABS_PACK ABS_FIXTURE ABS_MANIFEST ABS_BUILDER NEW_ABS_EVIDENCE or review ABS_EVIDENCE").into()),
    }
}
