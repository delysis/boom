//! Full production application workload; no user workspace or shown window.
use super::*;

pub(super) fn run(args: &[String]) -> Result<()> {
    require(
        args.len() == 8,
        "memory BUNDLE WRITING_PACK CONSULTATION_PACK PROTECTED_ROOT NEW_STUDY SOURCE_SHA256",
    )?;
    require(
        args[2..7].iter().all(|p| Path::new(p).is_absolute()),
        "Use absolute paths",
    )?;
    let bundle = Path::new(&args[2]);
    let study = Path::new(&args[6]);
    let executable = bundle.join("Contents/MacOS/Bloom");
    let inventory = bundle.join("Contents/Resources/source-files.sha256");
    let source_hash = digest_file(&inventory)?;
    require(source_hash == args[7], "Wrong application source")?;
    let executable_hash = digest_file(&executable)?;
    let mut models = Vec::new();
    for (index, purpose) in [(3, "writing"), (4, "consultation")] {
        let pack = Path::new(&args[index]);
        let path = pack.join("bloom-model.json");
        let manifest = json_file(&path)?;
        let identity = digest_file(&path)?;
        require(
            manifest["schema"] == 1
                && manifest["purpose"] == purpose
                && manifest["bits"] == 4
                && manifest["groupSize"] == 32
                && manifest["runtimeRevision"] == "9afc3b55f75a0d41a3d0c11330b9df6a036d24e4",
            "Unsupported local model",
        )?;
        verify_model(pack, &manifest)?;
        models.push(
            json!({"purpose":purpose,"directory":pack,"identity":identity,"manifest":manifest}),
        );
    }
    fs::create_dir(study)?;
    fs::copy(&inventory, study.join("source-files.sha256"))?;
    fs::copy(std::env::current_exe()?, study.join("owner"))?;
    write_new(
        &study.join("owner.rs"),
        include_bytes!("../bloom-literary-study.rs"),
    )?;
    write_new(&study.join("memory.rs"), include_bytes!("memory.rs"))?;
    let registration = json!({"schema":1,"executable":executable,"executable_sha256":executable_hash,
        "source_inventory_sha256":source_hash,"models":models,"application_bytes":24_u64<<30,
        "context_ceiling":16384,"full_input_tokens":16128,"full_output_reservation":256,
        "warm_input_tokens":4096,"deadline_seconds":900,"automatic_retries":false,
        "network_outbound_denied":true,"human_workspace_access_denied":true,
        "normal_workspace_access_denied":true,"foreground_activation":false,"keychain_access":false,
        "scope":"Production residency, encrypted per-update journals, concurrent offscreen native typing, full three-row writing and consultation contexts; not physical input or OS dialogs"});
    write_json(&study.join("registration.json"), &registration)?;
    let registration_hash = digest_file(&study.join("registration.json"))?;
    let protected = serde_json::to_string(&args[5])?;
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
        .arg(&executable)
        .args(["--mlx-smoke", "--memory-budget", "--pack"])
        .arg(&args[3])
        .arg("--consultation-pack")
        .arg(&args[4])
        .arg("--evidence")
        .arg(study.join("native"))
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
    let mut child = OwnedChild(command.spawn()?);
    let started = Instant::now();
    write_json(
        &study.join("started.json"),
        &json!({"pid":child.0.id(),"process_group":child.0.id()}),
    )?;
    println!("Owned application workload started: {}", child.0.id());
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
            && digest_file(&study.join("registration.json"))? == registration_hash,
        "Registered inputs changed",
    )?;
    for model in &models {
        let pack = Path::new(text(&model["directory"])?);
        require(
            digest_file(&pack.join("bloom-model.json"))? == model["identity"],
            "Model manifest changed",
        )?;
        verify_model(pack, &model["manifest"])?;
    }
    write_json(
        &study.join("inputs-after.json"),
        &json!({"all_registered_inputs_unchanged":true,"model_inventories_verified":true}),
    )?;
    require(
        status.success() && !timed_out,
        "Application workload failed; retain this attempt",
    )
}

fn integer(value: &Value) -> Result<u64> {
    value
        .as_u64()
        .ok_or_else(|| "Missing unsigned observation".into())
}
fn number(value: &Value) -> Result<f64> {
    let number = value.as_f64().ok_or("Missing numeric observation")?;
    require(number.is_finite() && number >= 0.0, "Invalid observation")?;
    Ok(number)
}
fn ledger(path: &Path) -> Result<Vec<u8>> {
    let info = fs::symlink_metadata(path)?;
    require(
        info.is_file() && info.len() <= 32 << 20,
        "Unsafe or oversized memory ledger",
    )?;
    let bytes = fs::read(path)?;
    require(
        bytes.len() <= 32 << 20,
        "Memory ledger grew beyond its bound",
    )?;
    Ok(bytes)
}
fn decode_rate(output: &Value) -> Result<f64> {
    let first = number(&output["first_token_seconds"])?;
    let elapsed = number(&output["elapsed_seconds"])?;
    let tokens = integer(&output["output_tokens"])?;
    require(elapsed >= first && tokens > 0, "Invalid decode interval")?;
    Ok(tokens.saturating_sub(1) as f64 / (elapsed - first).max(0.000001))
}

pub(super) fn review(study: &Path) -> Result<()> {
    let registration = json_file(&study.join("registration.json"))?;
    let owner = json_file(&study.join("owner-result.json"))?;
    require(
        owner["child_joined"] == true
            && owner["exit_code"] == 0
            && owner["timed_out"] == false
            && json_file(&study.join("inputs-after.json"))?["all_registered_inputs_unchanged"]
                == true,
        "Owner did not complete with unchanged inputs",
    )?;
    let native = study.join("native");
    let receipt = json_file(&native.join("receipt.json"))?;
    require(
        receipt["status"] == "execution_complete"
            && receipt["source_inventory_sha256"] == registration["source_inventory_sha256"]
            && digest_file(&study.join("source-files.sha256"))?
                == registration["source_inventory_sha256"]
            && receipt["limits"]["applicationBytes"] == 24_u64 << 30
            && receipt["durable_encrypted_checkpoint_overhead_included"] == true
            && receipt["full_writing_admitted_context"] == 16384
            && receipt["full_consultation_admitted_context"] == 16384,
        "Application scope or full context changed",
    )?;
    for model in array(&registration["models"])? {
        let purpose = text(&model["purpose"])?;
        require(
            receipt[format!("{purpose}_model")] == model["identity"]
                && json_file(&native.join(format!("{purpose}-manifest.json")))?
                    == model["manifest"],
            "Actually admitted model differs",
        )?;
    }
    let mut peak = 0;
    let mut mlx_peak = 0;
    let mut count = 0;
    let mut previous = 0.0;
    let mut phases = std::collections::BTreeMap::<String, (u64, u64)>::new();
    for line in ledger(&native.join("memory-samples.jsonl"))?
        .split(|b| *b == b'\n')
        .filter(|l| !l.is_empty())
    {
        let sample: Value = serde_json::from_slice(line)?;
        let time = number(&sample["seconds"])?;
        require(time >= previous, "Memory sample time moved backwards")?;
        previous = time;
        let current = integer(&sample["process_footprint_bytes"])?;
        let maximum = integer(&sample["kernel_process_peak_footprint_bytes"])?;
        require(
            current > 0 && maximum >= current,
            "Missing kernel accounting",
        )?;
        peak = peak.max(maximum);
        let mlx = integer(&sample["mlx_active_bytes"])?
            .checked_add(integer(&sample["mlx_cache_bytes"])?)
            .ok_or("Allocation overflow")?;
        mlx_peak = mlx_peak.max(mlx);
        count += 1;
        let phase = phases
            .entry(text(&sample["phase"])?.to_owned())
            .or_default();
        phase.0 += 1;
        phase.1 = phase.1.max(current);
    }
    require(
        count == integer(&receipt["memory_samples"])?
            && peak == integer(&receipt["peak_sampled_process_footprint_bytes"])?
            && [
                "load-consultation",
                "load-writing",
                "full-context-writing-three",
                "full-context-consultation",
            ]
            .iter()
            .all(|p| phases.contains_key(*p)),
        "Missing phase or inconsistent complete sample ledger",
    )?;
    let mut trials = Vec::new();
    for (name, width, input, maximum) in [
        ("warmup-writing", 1, 512, 16),
        ("warmup-consultation", 1, 512, 16),
        ("warm-writing-4k", 1, 4096, 256),
        ("warm-consultation-4k", 1, 4096, 256),
        ("full-context-writing-three", 3, 16128, 256),
        ("full-context-consultation", 1, 16128, 256),
        ("decode-cancellation-three", 3, 512, 256),
        ("after-cancellation", 1, 512, 16),
    ] {
        let trial = json_file(&native.join(format!("{name}.json")))?;
        let purpose = if name.contains("consultation") {
            "consultation"
        } else {
            "writing"
        };
        let seeds = match name {
            "warmup-writing" | "warmup-consultation" => json!([99]),
            "full-context-writing-three" => json!([42, 2026, 8675309]),
            "decode-cancellation-three" => json!([17, 42, 314]),
            "after-cancellation" => json!([17]),
            _ => json!([42]),
        };
        require(
            trial["model"] == receipt[format!("{purpose}_model")]
                && trial["generation_policy"] == receipt[format!("{purpose}_generation_policy")]
                && trial["seeds"] == seeds,
            "Trial model, policy or seeds differ",
        )?;
        require(
            trial["status"] == "complete"
                && trial["batch_width"] == width
                && trial["max_tokens_per_row"] == maximum,
            "Trial shape or output budget changed",
        )?;
        let outputs = array(&trial["outputs"])?;
        require(
            outputs.len() == width && array(&trial["journal_ids"])?.len() == width,
            "Lost row or journal attribution",
        )?;
        if width > 1 {
            let metrics = &trial["batch_metrics"];
            require(
                metrics["sharedPromptPrefills"] == 1
                    && metrics["width"] == width
                    && !array(&metrics["cacheBatchDimensions"])?.is_empty()
                    && array(&metrics["cacheBatchDimensions"])?
                        .iter()
                        .all(|d| d.as_u64() == Some(width as u64)),
                "Missing shared-prefill tensor batch",
            )?;
        }
        for output in outputs {
            let length = array(&output["token_ids"])?.len();
            require(
                output["prompt_tokens"] == input
                    && output["output_tokens"] == length
                    && length <= maximum
                    && input + length <= 16384,
                "Context or token ledger differs",
            )?;
            if name == "decode-cancellation-three" {
                require(
                    output["stop_reason"] == "cancelled" && length >= 8,
                    "Cancellation lost a row",
                )?;
            }
        }
        trials.push(trial);
    }
    let warm = [&trials[2]["outputs"][0], &trials[3]["outputs"][0]];
    let first = warm
        .iter()
        .map(|o| number(&o["first_token_seconds"]))
        .collect::<Result<Vec<_>>>()?;
    let rates = warm
        .iter()
        .map(|o| decode_rate(o))
        .collect::<Result<Vec<_>>>()?;
    for (output, rate) in warm.iter().zip(&rates) {
        require(
            (number(&output["sustained_decode_tokens_per_second"])? - rate).abs() <= 1e-9,
            "Recorded rate differs from token/time interval",
        )?;
    }
    let cancellation = number(&trials[6]["cancellation_join_seconds"])?;
    let typing = array(&receipt["typing_observations"])?;
    let delays = array(&receipt["typing_samples_seconds"])?;
    require(
        !typing.is_empty() && typing.len() == delays.len(),
        "No complete typing observations",
    )?;
    let mut typing_max: f64 = 0.0;
    for (observation, delay) in typing.iter().zip(delays) {
        let total = number(&observation["scheduled_delay_seconds"])?
            + number(&observation["insertion_seconds"])?
            + number(&observation["deletion_seconds"])?
            + number(&observation["layout_seconds"])?;
        let combined = number(&observation["combined_seconds"])?;
        require(
            (total - combined).abs() <= 1e-8 && number(delay)? == combined,
            "Typing components differ from total",
        )?;
        typing_max = typing_max.max(combined);
    }
    require(
        number(&receipt["maximum_typing_latency_seconds"])? == typing_max,
        "Typing maximum changed",
    )?;
    let minimum = integer(&receipt["sustained_decode_minimum_sample_tokens"])?;
    require(
        minimum >= 64,
        "Insufficient sustained-decode sample requirement",
    )?;
    let memory_ok = peak <= 24_u64 << 30 && mlx_peak <= 24_u64 << 30;
    let first_ok = first.iter().all(|s| *s <= 8.0);
    let rate_ok = rates.iter().all(|r| *r >= 10.0)
        && warm
            .iter()
            .all(|o| o["output_tokens"].as_u64().is_some_and(|n| n >= minimum));
    for (field, expected) in [
        ("application_budget_passed", memory_ok),
        ("warm_4k_first_response_passed", first_ok),
        ("sustained_decode_passed", rate_ok),
        ("decode_cancellation_passed", cancellation <= 2.0),
        ("offscreen_typing_passed", typing_max <= 0.1),
    ] {
        require(
            receipt[field] == expected,
            "Native target differs from its observations",
        )?;
    }
    let overlap = &receipt["overlap_load_admission_probe"];
    require(
        overlap["rejected_before_weight_loading"] == true
            && integer(&overlap["kernel_peak_growth_bytes"])? <= 64 << 20,
        "Overlap rejection was not bounded before loading",
    )?;
    write_json(
        &study.join("memory-review.json"),
        &json!({"status":"verified","source_inventory_sha256":registration["source_inventory_sha256"],
        "executable_sha256":registration["executable_sha256"],"models":registration["models"],"kernel_process_peak_bytes":peak,
        "sampled_mlx_peak_bytes":mlx_peak,"sample_count":count,"phases":phases,"warm_first_token_seconds":first,
        "warm_decode_rates":rates,"typing_samples":typing.len(),"typing_max_seconds":typing_max,"cancellation_join_seconds":cancellation,
        "memory_budget_passed":memory_ok,"warm_first_token_passed":first_ok,"sustained_decode_passed":rate_ok,
        "cancellation_passed":cancellation<=2.0,"offscreen_typing_passed":typing_max<=0.1,
        "all_measured_targets_passed":memory_ok&&first_ok&&rate_ok&&cancellation<=2.0&&typing_max<=0.1,
        "overlap_probe":overlap,"trials":trials,"physical_input_qualified":false,"keychain_dialogs_qualified":false,"distribution_qualified":false}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rate_excludes_first_token_and_rejects_impossible_intervals() {
        let output = json!({"first_token_seconds":2.0,"elapsed_seconds":12.0,"output_tokens":101});
        assert_eq!(decode_rate(&output).expect("interval"), 10.0);
        assert!(
            decode_rate(
                &json!({"first_token_seconds":12.0,"elapsed_seconds":2.0,"output_tokens":101})
            )
            .is_err()
        );
        assert!(
            decode_rate(
                &json!({"first_token_seconds":2.0,"elapsed_seconds":12.0,"output_tokens":0})
            )
            .is_err()
        );
    }
}
