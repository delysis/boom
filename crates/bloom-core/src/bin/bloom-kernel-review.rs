use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, error::Error, fs, io, path::Path};
type Result<T> = std::result::Result<T, Box<dyn Error>>;
fn require(ok: bool, message: &str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(io::Error::other(message).into())
    }
}
fn read(path: &Path) -> Result<Value> {
    let b = fs::read(path)?;
    require(b.len() <= 8_388_608, "JSON exceeds bound")?;
    Ok(serde_json::from_slice(&b)?)
}
fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn text(v: &Value) -> Result<&str> {
    v.as_str()
        .ok_or_else(|| io::Error::other("Missing string").into())
}
fn number(v: &Value) -> Result<f64> {
    v.as_f64()
        .filter(|x| x.is_finite() && *x >= 0.0)
        .ok_or_else(|| io::Error::other("Invalid observation").into())
}
fn output(path: &Path, rows: u64, columns: u64) -> Result<(Vec<f32>, String)> {
    let b = fs::read(path)?;
    require((8..=33_554_432).contains(&b.len()), "Tensor exceeds bound")?;
    let n = u64::from_le_bytes(b[..8].try_into()?) as usize;
    require(n <= 1_048_576 && n + 8 <= b.len(), "Invalid tensor header")?;
    let h: Value = serde_json::from_slice(&b[8..8 + n])?;
    let shape = &h["output"]["shape"];
    let count = rows
        .checked_mul(columns)
        .and_then(|v| v.checked_mul(4))
        .ok_or_else(|| io::Error::other("Tensor overflow"))?;
    require(
        h["output"]["dtype"] == "F32"
            && shape == &json!([rows, columns])
            && h["output"]["data_offsets"] == json!([0, count])
            && (b.len() - n - 8) as u64 == count,
        "Unexpected retained output",
    )?;
    let data = &b[n + 8..];
    let values = data
        .chunks_exact(4)
        .map(|p| f32::from_le_bytes(p.try_into().expect("Exact four-byte chunk")))
        .collect::<Vec<_>>();
    require(
        values.iter().all(|v| v.is_finite()),
        "Nonfinite retained output",
    )?;
    Ok((values, hash(data)))
}
fn median(mut values: Vec<f64>) -> Result<f64> {
    require(values.len() == 4, "Missing registered repeats")?;
    values.sort_by(f64::total_cmp);
    Ok((values[1] + values[2]) / 2.0)
}
fn main() -> Result<()> {
    let args = std::env::args().collect::<Vec<_>>();
    require(
        args.len() == 2 && Path::new(&args[1]).is_absolute(),
        "Use absolute evidence",
    )?;
    let root = Path::new(&args[1]);
    let target = root.join("independent-review.json");
    require(!target.exists(), "Review exists")?;
    let plan = read(&root.join("plan.json"))?;
    let r = read(&root.join("registration.json"))?;
    let done = read(&root.join("driver-complete.json"))?;
    require(
        done["exit_code"] == 0
            && done["child_joined"] == true
            && done["timed_out"] == false
            && done["source_pack_unchanged"] == true
            && done["shard_unchanged"] == true
            && done["configuration_unchanged"] == true
            && done["plan_unchanged"] == true,
        "Owned execution or binding failed",
    )?;
    require(
        r["plan_sha256"] == hash(&fs::read(root.join("plan.json"))?)
            && r["manifest_sha256"] == hash(&fs::read(root.join("model-manifest.json"))?)
            && r["network_outbound_denied"] == true
            && r["protected_workspace_denied"] == true,
        "Registered plan differs",
    )?;
    let native = read(&root.join("native/observations.json"))?;
    require(
        native["status"] == "complete"
            && native["pack_identity"] == r["pack_identity"]
            && native["shard_sha256"] == r["shard_sha256"],
        "Native binding differs",
    )?;
    let observations = native["observations"]
        .as_array()
        .ok_or_else(|| io::Error::other("Missing rows"))?;
    let cases = plan["cases"]
        .as_array()
        .ok_or_else(|| io::Error::other("Missing cases"))?;
    require(
        !cases.is_empty()
            && cases.len() <= 12
            && observations.len() == cases.len() * 16
            && r["registered_observations"] == observations.len()
            && r["registered_distinct_outputs"] == cases.len() * 4,
        "Missing registered observations",
    )?;
    let budget = r["operation_budget_bytes"]
        .as_u64()
        .ok_or_else(|| io::Error::other("Missing budget"))?;
    require(
        [4 * 1073741824, 8 * 1073741824].contains(&budget)
            && plan["operationBudgetBytes"] == budget
            && native["operation_budget_bytes"] == budget,
        "Budget differs",
    )?;
    let mut summaries = Vec::new();
    for case in cases {
        let name = text(&case["name"])?;
        let rows = case["rows"]
            .as_u64()
            .ok_or_else(|| io::Error::other("Missing width"))?;
        let columns = case["output"]
            .as_u64()
            .ok_or_else(|| io::Error::other("Missing columns"))?;
        let input = case["input"]
            .as_u64()
            .ok_or_else(|| io::Error::other("Missing input width"))?;
        let bits = case["bits"]
            .as_u64()
            .ok_or_else(|| io::Error::other("Missing bits"))?;
        let group = case["groupSize"]
            .as_u64()
            .ok_or_else(|| io::Error::other("Missing quantization group"))?;
        require(
            name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                && [1, 64, 512].contains(&rows)
                && [3840, 4096, 15360].contains(&columns)
                && [3840, 15360].contains(&input)
                && [4, 8].contains(&bits)
                && [32, 64].contains(&group),
            "Unexpected case",
        )?;
        let reference = output(
            &root.join(format!("native/{name}-fused.safetensors")),
            rows,
            columns,
        )?
        .0;
        let denominator = reference
            .iter()
            .map(|x| f64::from(*x).powi(2))
            .sum::<f64>()
            .sqrt();
        let mut by_arm = BTreeMap::<String, Vec<f64>>::new();
        for arm in ["fused", "dense-bf16", "dense-fp16", "cached-bf16"] {
            let (values, digest) = output(
                &root.join(format!("native/{name}-{arm}.safetensors")),
                rows,
                columns,
            )?;
            let error = values
                .iter()
                .zip(&reference)
                .map(|(a, b)| f64::from(*a) - f64::from(*b))
                .collect::<Vec<_>>();
            let maximum = error.iter().map(|v| v.abs()).fold(0.0_f64, f64::max);
            let relative = error.iter().map(|v| v * v).sum::<f64>().sqrt() / denominator.max(1e-12);
            for (index, expected) in case["arms"]
                .as_array()
                .ok_or_else(|| io::Error::other("Missing order"))?
                .iter()
                .enumerate()
            {
                if expected != arm {
                    continue;
                }
                let found = observations
                    .iter()
                    .filter(|v| v["case"] == name && v["trial"] == index)
                    .collect::<Vec<_>>();
                require(found.len() == 1, "Duplicate or missing observation")?;
                let observation = found[0];
                require(
                    observation["arm"] == arm
                        && observation["output_sha256"] == digest
                        && observation["finite"] == true
                        && observation["rows"] == rows
                        && observation["output"] == columns
                        && observation["input"] == input
                        && observation["bits"] == bits
                        && observation["group_size"] == group
                        && observation["seed"] == 42,
                    "Output, geometry or scheduled order differs",
                )?;
                require(
                    number(&observation["cached_conversion_seconds"])? > 0.0
                        && observation["cached_weight_bytes"] == input * columns * 2,
                    "Cached weight size or conversion timing differs",
                )?;
                require(
                    (number(&observation["maximum_absolute_error"])? - maximum).abs() <= 1e-6
                        && (number(&observation["relative_rmse"])? - relative).abs() <= 1e-5,
                    "Native error statistic differs",
                )?;
                let seconds = number(&observation["seconds"])?;
                require(
                    seconds > 0.0 && number(&observation["mlx_peak_bytes"])? <= budget as f64,
                    "Timing or allocation exceeds bound",
                )?;
                by_arm.entry(arm.to_owned()).or_default().push(seconds);
            }
        }
        let base = median(by_arm["fused"].clone())?;
        let bf16 = median(by_arm["dense-bf16"].clone())?;
        let fp16 = median(by_arm["dense-fp16"].clone())?;
        let cached = median(by_arm["cached-bf16"].clone())?;
        summaries.push(json!({"case":name,"rows":rows,"bits":bits,"group_size":group,"input":input,"output":columns,"fused_median_seconds":base,"dense_bf16_median_seconds":bf16,
            "dense_fp16_median_seconds":fp16,"cached_bf16_median_seconds":cached,
            "bf16_speed_ratio":base/bf16,"fp16_speed_ratio":base/fp16,"cached_bf16_speed_ratio":base/cached}));
    }
    fs::write(
        target,
        serde_json::to_vec_pretty(
            &json!({"status":"passed","observations_checked":observations.len(),"full_outputs_checked":cases.len()*4,
        "pack_identity":r["pack_identity"],"cases":summaries,"product_performance_qualified":false,
        "scope":"independent saved-output hashes, numeric differences, geometry/order and bounded timing review"}),
        )?,
    )?;
    println!(
        "All {} observations and {} complete kernel outputs verified.",
        observations.len(),
        cases.len() * 4
    );
    Ok(())
}
