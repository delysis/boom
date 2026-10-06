use serde_json::{Value, json};
use std::{
    error::Error,
    fs, io,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
type Result<T> = std::result::Result<T, Box<dyn Error>>;
fn require(ok: bool, message: &str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(io::Error::other(message).into())
    }
}
fn hash(path: &Path) -> Result<String> {
    let out = Command::new("/usr/bin/shasum")
        .args(["-a", "256"])
        .arg(path)
        .output()?;
    require(out.status.success(), "Hash failed")?;
    Ok(String::from_utf8(out.stdout)?
        .split_whitespace()
        .next()
        .ok_or_else(|| io::Error::other("Missing hash"))?
        .to_owned())
}
fn read(path: &Path) -> Result<Value> {
    let meta = fs::symlink_metadata(path)?;
    require(
        meta.is_file() && meta.len() <= 8_388_608,
        "Unexpected JSON file",
    )?;
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}
fn main() -> Result<()> {
    let args = std::env::args().collect::<Vec<_>>();
    require(
        cfg!(target_os = "macos"),
        "The MLX kernel screen requires macOS",
    )?;
    require(
        args.len() == 4 && args[1..].iter().all(|v| Path::new(v).is_absolute()),
        "Use ABSOLUTE_PACK ABSOLUTE_BUILDER NEW_ABSOLUTE_EVIDENCE",
    )?;
    let pack = PathBuf::from(&args[1]);
    let executable = PathBuf::from(&args[2]);
    let evidence = PathBuf::from(&args[3]);
    require(
        pack.is_dir() && executable.is_file() && !evidence.exists(),
        "Require an existing pack and developer executable, and fresh evidence",
    )?;
    fs::create_dir(&evidence)?;
    let manifest = pack.join("bloom-model.json");
    let identity = hash(&manifest)?;
    require(
        identity == "3639bf3342065eb1b2da2bb0ffc786266ee5e5964bdc5727b75e5a410db35cc9",
        "Unexpected source pack",
    )?;
    let metadata = read(&manifest)?;
    let shard_name = "model-00001-of-00008.safetensors";
    let expected = metadata["files"]
        .as_array()
        .ok_or_else(|| io::Error::other("Missing files"))?
        .iter()
        .find(|v| v["path"] == shard_name)
        .ok_or_else(|| io::Error::other("Missing shard"))?;
    let shard = pack.join(shard_name);
    require(
        expected["bytes"].as_u64() == Some(fs::metadata(&shard)?.len())
            && expected["sha256"] == hash(&shard)?,
        "Source shard differs",
    )?;
    let mut cases = Vec::new();
    for (name, tensor, output) in [
        (
            "attention",
            "language_model.model.layers.0.self_attn.q_proj",
            4096,
        ),
        ("mlp", "language_model.model.layers.0.mlp.gate_proj", 15360),
    ] {
        for rows in [1, 64, 512] {
            cases.push(json!({"name":format!("{name}-{rows}"), "tensor":tensor, "input":3840, "output":output,
                "rows":rows, "seed":42, "arms":["fused","dense-bf16","dense-fp16","dense-fp16","dense-bf16","fused",
                "fused","dense-bf16","dense-fp16","dense-fp16","dense-bf16","fused"]}));
        }
    }
    let plan = json!({"shard":shard, "shardSHA256":expected["sha256"],"packIdentity":identity,
        "output":evidence.join("native"),"cases":cases});
    let plan_path = evidence.join("plan.json");
    fs::write(&plan_path, serde_json::to_vec_pretty(&plan)?)?;
    let registration = json!({"executable":executable,"executable_sha256":hash(&executable)?,
        "plan_sha256":hash(&plan_path)?,"pack_identity":identity,"shard_sha256":expected["sha256"],
        "network_outbound_denied":true,"scope":"owned developer arithmetic screen; no product qualification",
        "deadline_seconds":120,"registered_observations":72,"registered_distinct_outputs":18});
    fs::write(
        evidence.join("registration.json"),
        serde_json::to_vec_pretty(&registration)?,
    )?;
    let stdout = fs::File::create(evidence.join("native.stdout"))?;
    let stderr = fs::File::create(evidence.join("native.stderr"))?;
    let started = Instant::now();
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command
        .args([
            "-p",
            "(version 1) (allow default) (deny network-outbound)",
            "/usr/bin/time",
            "-l",
        ])
        .arg(&executable)
        .arg("--prefill-kernel-probe")
        .arg(&plan_path)
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(stderr);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn()?;
    let pid = child.id();
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if started.elapsed() > Duration::from_secs(120) {
            timed_out = true;
            let group = format!("-{}", child.id());
            let killed = Command::new("/bin/kill")
                .args(["-KILL", "--", &group])
                .status()?;
            require(
                killed.success(),
                "Could not terminate the owned probe group",
            )?;
            break child.wait()?;
        }
        thread::sleep(Duration::from_millis(100));
    };
    let result = json!({"pid":pid,"exit_code":status.code(),"timed_out":timed_out,"elapsed_seconds":started.elapsed().as_secs_f64(),
        "child_joined":true,"executable_unchanged":registration["executable_sha256"] == hash(&executable)?,
        "source_pack_unchanged":identity == hash(&manifest)?, "shard_unchanged":expected["sha256"] == hash(&shard)?,"plan_unchanged":registration["plan_sha256"] == hash(&plan_path)?});
    fs::write(
        evidence.join("driver-complete.json"),
        serde_json::to_vec_pretty(&result)?,
    )?;
    require(
        status.success()
            && !timed_out
            && result["executable_unchanged"] == true
            && result["source_pack_unchanged"] == true
            && result["shard_unchanged"] == true
            && result["plan_unchanged"] == true,
        "Probe failed; all observations retained",
    )?;
    println!("Owned probe completed; evidence {}", evidence.display());
    Ok(())
}
