use serde_json::{Value, json};
use std::{
    error::Error,
    fs, io,
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};
type Result<T> = std::result::Result<T, Box<dyn Error>>;
const PUBLIC_MODEL: &str =
    "mlx-community/gemma-4-12B-it-qat-4bit@e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6";
const PROTECTED: &str = "/Users/george/Documents/Codex/2026-10-04/hi-sol-6-1-new-model/work/editions-native-author-check/workspace";
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
struct OwnedChild {
    child: Child,
    joined: bool,
}
impl OwnedChild {
    fn stop(&mut self) -> Result<ExitStatus> {
        let group = format!("-{}", self.child.id());
        let killed = Command::new("/bin/kill")
            .args(["-KILL", "--", &group])
            .status()?;
        if !killed.success() {
            let _ = self.child.kill();
        }
        let result = self.child.wait()?;
        self.joined = true;
        Ok(result)
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if !self.joined {
            let _ = self.stop();
        }
    }
}
fn main() -> Result<()> {
    let args = std::env::args().collect::<Vec<_>>();
    require(
        cfg!(target_os = "macos"),
        "The MLX kernel screen requires macOS",
    )?;
    require(
        [4, 5].contains(&args.len()) && args[1..].iter().all(|v| Path::new(v).is_absolute()),
        "Use ABSOLUTE_PACK ABSOLUTE_BUILDER NEW_ABSOLUTE_EVIDENCE [ABSOLUTE_PUBLIC_MANIFEST]",
    )?;
    let pack = PathBuf::from(&args[1]);
    let executable = PathBuf::from(&args[2]);
    let evidence = PathBuf::from(&args[3]);
    require(
        pack.is_dir() && executable.is_file() && !evidence.exists(),
        "Require an existing pack and developer executable, and fresh evidence",
    )?;
    fs::create_dir(&evidence)?;
    let public = args.len() == 5;
    let manifest = if public {
        PathBuf::from(&args[4])
    } else {
        pack.join("bloom-model.json")
    };
    let manifest_hash = hash(&manifest)?;
    let metadata = read(&manifest)?;
    fs::copy(&manifest, evidence.join("model-manifest.json"))?;
    let identity = if public {
        require(
            metadata["identity"] == PUBLIC_MODEL && metadata["purpose"] == "consultation",
            "Unexpected public checkpoint",
        )?;
        PUBLIC_MODEL.to_owned()
    } else {
        require(
            manifest_hash == "3639bf3342065eb1b2da2bb0ffc786266ee5e5964bdc5727b75e5a410db35cc9",
            "Unexpected source pack",
        )?;
        manifest_hash.clone()
    };
    let shard_name = if public {
        "model-00001-of-00003.safetensors"
    } else {
        "model-00001-of-00008.safetensors"
    };
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
    let mut source_bindings = Vec::new();
    let configuration = if public {
        for name in ["config.json", "model.safetensors.index.json"] {
            let entry = metadata["files"]
                .as_array()
                .and_then(|a| a.iter().find(|v| v["path"] == name))
                .ok_or_else(|| io::Error::other("Missing configuration inventory"))?;
            let path = pack.join(name);
            let digest = hash(&path)?;
            require(
                entry["sha256"] == digest
                    && entry["bytes"].as_u64() == Some(fs::metadata(&path)?.len()),
                "Configuration differs",
            )?;
            source_bindings.push((path, digest));
        }
        read(&pack.join("config.json"))?
    } else {
        Value::Null
    };
    let index = if public {
        read(&pack.join("model.safetensors.index.json"))?
    } else {
        Value::Null
    };
    let tensors = if public {
        vec![
            (
                "attention",
                "language_model.model.layers.0.self_attn.q_proj",
                3840,
                4096,
            ),
            (
                "mlp-gate",
                "language_model.model.layers.0.mlp.gate_proj",
                3840,
                15360,
            ),
            (
                "mlp-up",
                "language_model.model.layers.0.mlp.up_proj",
                3840,
                15360,
            ),
            (
                "mlp-down",
                "language_model.model.layers.0.mlp.down_proj",
                15360,
                3840,
            ),
        ]
    } else {
        vec![
            (
                "attention",
                "language_model.model.layers.0.self_attn.q_proj",
                3840,
                4096,
            ),
            (
                "mlp",
                "language_model.model.layers.0.mlp.gate_proj",
                3840,
                15360,
            ),
        ]
    };
    let mut cases = Vec::new();
    for (name, tensor, input, output) in tensors {
        let (bits, group) = if public {
            for suffix in ["weight", "scales", "biases"] {
                require(
                    index["weight_map"][format!("{tensor}.{suffix}")] == shard_name,
                    "Tensor moved to another shard",
                )?;
            }
            let q = configuration["quantization"]
                .get(tensor)
                .unwrap_or(&configuration["quantization"]);
            let bits = q["bits"]
                .as_u64()
                .ok_or_else(|| io::Error::other("Missing quantization bits"))?;
            let group = q["group_size"]
                .as_u64()
                .ok_or_else(|| io::Error::other("Missing quantization group"))?;
            require(
                group == 64 && bits == if name == "attention" { 4 } else { 8 },
                "Unexpected public quantization",
            )?;
            (bits, group)
        } else {
            (4, 32)
        };
        for rows in [1, 64, 512] {
            cases.push(json!({"name":format!("{name}-{rows}"), "tensor":tensor, "input":input, "output":output,
                "bits":bits,"groupSize":group,
                "rows":rows, "seed":42, "arms":["fused","dense-bf16","dense-fp16","cached-bf16","cached-bf16","dense-fp16","dense-bf16","fused",
                "fused","dense-bf16","dense-fp16","cached-bf16","cached-bf16","dense-fp16","dense-bf16","fused"]}));
        }
    }
    let budget = if public { 8_u64 } else { 4 } * 1_073_741_824;
    let plan = json!({"shard":shard, "shardSHA256":expected["sha256"],"packIdentity":identity,"operationBudgetBytes":budget,
        "output":evidence.join("native"),"cases":cases});
    let plan_path = evidence.join("plan.json");
    fs::write(&plan_path, serde_json::to_vec_pretty(&plan)?)?;
    let registration = json!({"executable":executable,"executable_sha256":hash(&executable)?,
        "plan_sha256":hash(&plan_path)?,"pack_identity":identity,"shard_sha256":expected["sha256"],
        "manifest_sha256":manifest_hash,"source_bindings":source_bindings,
        "environment":{"MLX_METAL_MAX_OPS":"50","MLX_METAL_MAX_MB":"50","MLX_METAL_GPU_ARCH":"removed","MTL_CAPTURE_ENABLED":"removed"},
        "operation_budget_bytes":budget,"protected_workspace_denied":true,
        "network_outbound_denied":true,"scope":"owned developer arithmetic screen; no product qualification",
        "deadline_seconds":120,"registered_observations":cases.len()*16,"registered_distinct_outputs":cases.len()*4});
    fs::write(
        evidence.join("registration.json"),
        serde_json::to_vec_pretty(&registration)?,
    )?;
    let stdout = fs::File::create(evidence.join("native.stdout"))?;
    let stderr = fs::File::create(evidence.join("native.stderr"))?;
    let started = Instant::now();
    let mut command = Command::new("/usr/bin/sandbox-exec");
    let sandbox = format!(
        "(version 1) (allow default) (deny network-outbound) (deny file-read* file-write* (subpath \"{PROTECTED}\"))"
    );
    command
        .args(["-p", &sandbox, "/usr/bin/time", "-l"])
        .arg(&executable)
        .arg("--prefill-kernel-probe")
        .arg(&plan_path)
        .env("MLX_METAL_MAX_OPS", "50")
        .env("MLX_METAL_MAX_MB", "50")
        .env_remove("MLX_METAL_GPU_ARCH")
        .env_remove("MTL_CAPTURE_ENABLED")
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(stderr);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut owner = OwnedChild {
        child: command.spawn()?,
        joined: false,
    };
    let pid = owner.child.id();
    fs::write(
        evidence.join("owner.json"),
        serde_json::to_vec_pretty(&json!({"pid":pid,"process_group":pid}))?,
    )?;
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = owner.child.try_wait()? {
            owner.joined = true;
            break status;
        }
        if started.elapsed() > Duration::from_secs(120) {
            timed_out = true;
            break owner.stop()?;
        }
        thread::sleep(Duration::from_millis(100));
    };
    let result = json!({"pid":pid,"exit_code":status.code(),"timed_out":timed_out,"elapsed_seconds":started.elapsed().as_secs_f64(),
        "child_joined":true,"executable_unchanged":registration["executable_sha256"] == hash(&executable)?,
        "source_pack_unchanged":manifest_hash == hash(&manifest)?, "shard_unchanged":expected["sha256"] == hash(&shard)?,"plan_unchanged":registration["plan_sha256"] == hash(&plan_path)?,
        "configuration_unchanged":source_bindings.iter().map(|(p,h)| Ok(h == &hash(p)?)).collect::<Result<Vec<_>>>()?.into_iter().all(|v| v)});
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
            && result["configuration_unchanged"] == true
            && result["plan_unchanged"] == true,
        "Probe failed; all observations retained",
    )?;
    println!("Owned probe completed; evidence {}", evidence.display());
    Ok(())
}
