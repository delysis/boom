//! Synthetic saved-output controls for the actual component reviewer executable.
//! These artifacts establish receipt admission, never real model execution.
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    error::Error,
    fs,
    path::{Path, PathBuf},
    process::Command,
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn write(path: &Path, value: &Value) -> Result<()> {
    fs::write(path, serde_json::to_vec_pretty(value)?)?;
    Ok(())
}

fn fixture(executable_unchanged: bool) -> Result<PathBuf> {
    let root = std::env::temp_dir().join(format!("bloom-kernel-review-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&root)?;
    fs::create_dir(root.join("native"))?;
    let arms = [
        "fused",
        "dense-bf16",
        "dense-fp16",
        "cached-bf16",
        "cached-bf16",
        "dense-fp16",
        "dense-bf16",
        "fused",
        "fused",
        "dense-bf16",
        "dense-fp16",
        "cached-bf16",
        "cached-bf16",
        "dense-fp16",
        "dense-bf16",
        "fused",
    ];
    let budget = 4_u64 * 1_073_741_824;
    write(
        &root.join("plan.json"),
        &json!({"operationBudgetBytes": budget,
        "cases": [{"name":"synthetic-1","rows":1,"input":3840,"output":3840,
        "bits":4,"groupSize":32,"arms":arms}]}),
    )?;
    write(
        &root.join("model-manifest.json"),
        &json!({"synthetic":true}),
    )?;
    let data = vec![0; 3840 * 4];
    let header = serde_json::to_vec(&json!({"output": {"dtype":"F32","shape":[1,3840],
        "data_offsets":[0,data.len()]}}))?;
    let mut tensor = (header.len() as u64).to_le_bytes().to_vec();
    tensor.extend(header);
    tensor.extend(&data);
    for arm in ["fused", "dense-bf16", "dense-fp16", "cached-bf16"] {
        fs::write(
            root.join(format!("native/synthetic-1-{arm}.safetensors")),
            &tensor,
        )?;
    }
    let observations = arms
        .into_iter()
        .enumerate()
        .map(|(trial, arm)| {
            json!({
                "case":"synthetic-1","trial":trial,"arm":arm,"output_sha256":hash(&data),
                "finite":true,"rows":1,"input":3840,"output":3840,"bits":4,"group_size":32,
                "seed":42,"cached_conversion_seconds":0.01,"cached_weight_bytes":3840_u64*3840*2,
                "maximum_absolute_error":0.0,"relative_rmse":0.0,"seconds":1.0,"mlx_peak_bytes":0,
            })
        })
        .collect::<Vec<_>>();
    write(
        &root.join("native/observations.json"),
        &json!({"status":"complete",
        "pack_identity":"synthetic","shard_sha256":"synthetic",
        "operation_budget_bytes":budget,"observations":observations}),
    )?;
    write(
        &root.join("registration.json"),
        &json!({
            "plan_sha256":hash(&fs::read(root.join("plan.json"))?),
            "manifest_sha256":hash(&fs::read(root.join("model-manifest.json"))?),
            "network_outbound_denied":true,"protected_workspace_denied":true,
            "registered_observations":16,"registered_distinct_outputs":4,
            "pack_identity":"synthetic","shard_sha256":"synthetic","operation_budget_bytes":budget,
        }),
    )?;
    write(
        &root.join("driver-complete.json"),
        &json!({"exit_code":0,"child_joined":true,
        "timed_out":false,"source_pack_unchanged":true,"shard_unchanged":true,
        "configuration_unchanged":true,"plan_unchanged":true,
        "executable_unchanged":executable_unchanged}),
    )?;
    Ok(root)
}

#[test]
fn real_reviewer_accepts_unchanged_producer_and_rejects_changed_producer() -> Result<()> {
    for unchanged in [true, false] {
        let root = fixture(unchanged)?;
        let output = Command::new(env!("CARGO_BIN_EXE_bloom-kernel-review"))
            .arg(&root)
            .output()?;
        assert_eq!(
            output.status.success(),
            unchanged,
            "fixture {} stderr {}",
            root.display(),
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(root.join("independent-review.json").exists(), unchanged);
        fs::remove_dir_all(root)?;
    }
    Ok(())
}
