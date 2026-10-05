//! Developer delivery tool. Native tools own signing and packaging; Rust owns
//! admission and immutable command receipts. It never submits to Apple or runs Bloom.
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    env,
    ffi::{OsStr, OsString},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Profile {
    Development,
    Distribution,
}

impl Profile {
    fn parse(value: &OsStr) -> Result<Self> {
        match value.to_str() {
            Some("development") => Ok(Self::Development),
            Some("distribution") => Ok(Self::Distribution),
            _ => Err("Choose development or distribution signing.".into()),
        }
    }

    fn timestamp(self) -> &'static str {
        match self {
            Self::Development => "--timestamp=none",
            Self::Distribution => "--timestamp",
        }
    }

    fn accepts(self, authority: &str) -> bool {
        authority.starts_with(match self {
            Self::Development => "Apple Development: ",
            Self::Distribution => "Developer ID Application: ",
        })
    }
}

fn save(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

fn hash(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 65_536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            return Ok(format!("{:x}", digest.finalize()));
        }
        digest.update(&buffer[..count]);
    }
}

fn absolute(path: &OsStr) -> Result<PathBuf> {
    let path = Path::new(path);
    if !path.is_absolute() {
        return Err("Use absolute bundle and evidence paths.".into());
    }
    Ok(path.to_path_buf())
}

struct Receipts {
    root: PathBuf,
}

impl Receipts {
    fn command(&self, label: &str, program: &str, args: &[OsString]) -> Result<Output> {
        // Write intent before starting. Failed or interrupted operations stay visible.
        save(
            &self.root.join(format!("{label}-command.json")),
            &serde_json::to_vec_pretty(&json!({
                "program": program,
                "arguments": args.iter().map(|v| v.to_string_lossy()).collect::<Vec<_>>(),
            }))?,
        )?;
        let result = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .output();
        match result {
            Ok(output) => {
                save(&self.root.join(format!("{label}.stdout")), &output.stdout)?;
                save(&self.root.join(format!("{label}.stderr")), &output.stderr)?;
                save(
                    &self.root.join(format!("{label}-result.json")),
                    &serde_json::to_vec_pretty(
                        &json!({"exit_code": output.status.code(), "success": output.status.success()}),
                    )?,
                )?;
                if !output.status.success() {
                    return Err(
                        format!("{label} failed; its command and output are retained.").into(),
                    );
                }
                Ok(output)
            }
            Err(error) => {
                save(
                    &self.root.join(format!("{label}-result.json")),
                    &serde_json::to_vec_pretty(&json!({"spawn_error": error.to_string()}))?,
                )?;
                Err(error.into())
            }
        }
    }

    fn plist(&self, label: &str, path: &Path) -> Result<Value> {
        let result = self.command(
            label,
            "/usr/bin/plutil",
            &[
                "-convert".into(),
                "json".into(),
                "-o".into(),
                "-".into(),
                path.into(),
            ],
        )?;
        Ok(serde_json::from_slice(&result.stdout)?)
    }
}

fn text(output: &Output) -> Result<String> {
    Ok(format!(
        "{}\n{}",
        std::str::from_utf8(&output.stdout)?,
        std::str::from_utf8(&output.stderr)?
    ))
}

fn field<'a>(scope: &'a str, prefix: &str) -> Result<&'a str> {
    let mut values = scope.lines().filter_map(|line| line.strip_prefix(prefix));
    let value = values
        .next()
        .ok_or_else(|| format!("Missing signing field: {prefix}"))?;
    if value.is_empty() || values.next().is_some() {
        return Err(format!("Ambiguous signing field: {prefix}").into());
    }
    Ok(value)
}

fn check_entitlements(value: &Value) -> Result<()> {
    if *value != json!({"com.apple.security.device.audio-input": true}) {
        return Err("Signed entitlements must grant only Boolean microphone access.".into());
    }
    Ok(())
}

fn source_hash(info: &Value, key: &str, path: &Path) -> Result<String> {
    let expected = info[key]
        .as_str()
        .ok_or("Missing signed source/lock identity.")?;
    if expected.len() != 64
        || !expected
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || hash(path)? != expected
    {
        return Err(format!("Signed inventory mismatch: {key}").into());
    }
    Ok(expected.to_owned())
}

#[derive(Debug, Serialize)]
struct Inspection {
    edition: String,
    authority: String,
    team_identifier: String,
    timestamp: Option<String>,
    designated_requirement: String,
    executable_sha256: String,
    source_inventory_sha256: String,
    dependency_locks_sha256: String,
    model_catalog_sha256: String,
    preparation_issues: Vec<String>,
}

fn preparation_issues(authority: &str, timestamp: Option<&str>) -> Vec<String> {
    let mut issues = Vec::new();
    if !Profile::Distribution.accepts(authority) {
        issues.push("A Developer ID Application signature is required.".into());
    }
    if timestamp.is_none_or(|v| v.is_empty() || v == "none") {
        issues.push("A secure signing timestamp is required.".into());
    }
    issues
}

fn runtime_enabled(code_directory: &str) -> Result<bool> {
    let flags = code_directory
        .split_whitespace()
        .find_map(|s| s.strip_prefix("flags=0x"))
        .ok_or("Missing native code-signing flags.")?;
    let number = flags.split('(').next().ok_or("Missing flag value.")?;
    Ok(u32::from_str_radix(number, 16)? & 0x10000 != 0)
}

fn check_bundle_files(app: &Path) -> Result<()> {
    let executable = app.join("Contents/MacOS/Bloom");
    let mut pending = vec![app.to_path_buf()];
    let mut count = 0_usize;
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            count += 1;
            if count > 4096 {
                return Err("Bundle exceeds the delivery file limit.".into());
            }
            let kind = entry.file_type()?;
            if kind.is_symlink() || (!kind.is_file() && !kind.is_dir()) {
                return Err(
                    "Delivery accepts Bloom's regular, self-contained bundle files.".into(),
                );
            }
            if kind.is_dir() {
                pending.push(entry.path());
            } else {
                let mut header = [0_u8; 4];
                match File::open(entry.path())?.read_exact(&mut header) {
                    Ok(()) => {
                        let magic = u32::from_be_bytes(header);
                        if matches!(
                            magic,
                            0xfeed_face
                                | 0xcefa_edfe
                                | 0xfeed_facf
                                | 0xcffa_edfe
                                | 0xcafe_babe
                                | 0xbeba_feca
                                | 0xcafe_babf
                                | 0xbfba_feca
                        ) && entry.path() != executable
                        {
                            return Err("Unexpected nested executable; its signing must be designed explicitly.".into());
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => {}
                    Err(error) => return Err(error.into()),
                }
            }
        }
    }
    Ok(())
}

fn inspect(app: &Path, receipts: &Receipts) -> Result<Inspection> {
    check_bundle_files(app)?;
    let info = receipts.plist("bundle-info", &app.join("Contents/Info.plist"))?;
    if info["CFBundleIdentifier"] != "com.delysis.Bloom"
        || info["CFBundleExecutable"] != "Bloom"
        || info["CFBundlePackageType"] != "APPL"
        || !matches!(info["BloomEdition"].as_str(), Some("author" | "chat"))
        || info["NSMicrophoneUsageDescription"]
            .as_str()
            .is_none_or(str::is_empty)
        || info["NSSpeechRecognitionUsageDescription"]
            .as_str()
            .is_none_or(str::is_empty)
    {
        return Err("Bundle identity, edition or signed privacy descriptions are invalid.".into());
    }
    receipts.command(
        "signature-verification",
        "/usr/bin/codesign",
        &[
            "--verify".into(),
            "--deep".into(),
            "--strict".into(),
            "--test-requirement".into(),
            "=identifier \"com.delysis.Bloom\" and anchor apple generic".into(),
            app.into(),
        ],
    )?;
    let entitlements = receipts.command(
        "entitlements",
        "/usr/bin/codesign",
        &[
            "-d".into(),
            "--entitlements".into(),
            "-".into(),
            "--xml".into(),
            app.into(),
        ],
    )?;
    let entitlement_path = receipts.root.join("signed-entitlements.plist");
    save(&entitlement_path, &entitlements.stdout)?;
    check_entitlements(&receipts.plist("entitlement-values", &entitlement_path)?)?;
    let scope = text(&receipts.command(
        "signing-scope",
        "/usr/bin/codesign",
        &["-dv".into(), "--verbose=4".into(), app.into()],
    )?)?;
    let code_directory = field(&scope, "CodeDirectory ")?;
    if !runtime_enabled(code_directory)? {
        return Err("The signed executable does not enable the hardened runtime.".into());
    }
    if !field(&scope, "Sealed Resources ")?.starts_with("version=2 ") {
        return Err("Missing sealed bundle resources.".into());
    }
    // Authority repeats for the chain: the first entry is the actual leaf signer.
    let authority = scope
        .lines()
        .find_map(|s| s.strip_prefix("Authority="))
        .ok_or("Missing signing authority.")?;
    let timestamp = if scope.lines().any(|s| s.starts_with("Timestamp=")) {
        Some(field(&scope, "Timestamp=")?)
    } else {
        None
    };
    if Profile::Distribution.accepts(authority) {
        receipts.command(
            "developer-id-certificate",
            "/usr/bin/codesign",
            &[
                "--verify".into(), "--strict".into(), "--test-requirement".into(),
                "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists".into(),
                app.into(),
            ],
        )?;
    }
    let requirement = text(&receipts.command(
        "designated-requirement",
        "/usr/bin/codesign",
        &["-d".into(), "-r-".into(), app.into()],
    )?)?;
    let resources = app.join("Contents/Resources");
    Ok(Inspection {
        edition: info["BloomEdition"]
            .as_str()
            .ok_or("Missing edition.")?
            .to_owned(),
        authority: authority.to_owned(),
        team_identifier: field(&scope, "TeamIdentifier=")?.to_owned(),
        timestamp: timestamp.map(str::to_owned),
        designated_requirement: field(&requirement, "designated => ")?.to_owned(),
        executable_sha256: hash(&app.join("Contents/MacOS/Bloom"))?,
        source_inventory_sha256: source_hash(
            &info,
            "BoomSourceSHA256",
            &resources.join("source-files.sha256"),
        )?,
        dependency_locks_sha256: source_hash(
            &info,
            "BoomDependencyLockSHA256",
            &resources.join("dependency-locks.sha256"),
        )?,
        model_catalog_sha256: hash(
            &resources.join("Boom_Boom.bundle/Contents/Resources/ModelCatalog.json"),
        )?,
        preparation_issues: preparation_issues(authority, timestamp),
    })
}

fn sign(app: &Path, receipts: &Receipts, args: &[OsString]) -> Result<Inspection> {
    check_bundle_files(app)?;
    let profile = Profile::parse(&args[0])?;
    let entitlements = absolute(&args[2])?;
    check_entitlements(&receipts.plist("input-entitlements", &entitlements)?)?;
    receipts.command(
        "sign",
        "/usr/bin/codesign",
        &[
            "--force".into(),
            "--options".into(),
            "runtime".into(),
            profile.timestamp().into(),
            "--entitlements".into(),
            entitlements.into_os_string(),
            "--sign".into(),
            args[1].clone(),
            app.into(),
        ],
    )?;
    let result = inspect(app, receipts)?;
    if !profile.accepts(&result.authority)
        || (profile == Profile::Distribution && !result.preparation_issues.is_empty())
    {
        return Err(
            "Actual signer or timestamp does not match the requested signing profile.".into(),
        );
    }
    Ok(result)
}

fn archive(app: &Path, receipts: &Receipts, stage: &OsStr) -> Result<Inspection> {
    if stage != "submission" && stage != "notarized" {
        return Err("Choose submission or notarized archive stage.".into());
    }
    let result = inspect(app, receipts)?;
    if !result.preparation_issues.is_empty() {
        save(
            &receipts.root.join("inspection.json"),
            &serde_json::to_vec_pretty(&result)?,
        )?;
        return Err(
            "Bundle is ineligible for distribution preparation; inspection retained.".into(),
        );
    }
    let copy = receipts.root.join("bundle");
    fs::create_dir(&copy)?;
    let copy = copy.join(app.file_name().ok_or("Missing bundle name.")?);
    receipts.command(
        "copy-bundle",
        "/usr/bin/ditto",
        &[app.into(), copy.as_os_str().into()],
    )?;
    let copy_receipts = Receipts {
        root: receipts.root.join("copied-inspection"),
    };
    fs::create_dir(&copy_receipts.root)?;
    let copied = inspect(&copy, &copy_receipts)?;
    if serde_json::to_value(&copied)? != serde_json::to_value(&result)? {
        return Err("Bundle changed during delivery copy; both inspections retained.".into());
    }
    if stage == "notarized" {
        receipts.command(
            "staple-validation",
            "/usr/bin/xcrun",
            &["stapler".into(), "validate".into(), copy.as_os_str().into()],
        )?;
        let assessment = text(&receipts.command(
            "gatekeeper",
            "/usr/sbin/spctl",
            &[
                "--assess".into(),
                "--type".into(),
                "execute".into(),
                "--verbose=4".into(),
                "--ignore-cache".into(),
                copy.as_os_str().into(),
            ],
        )?)?;
        if field(&assessment, "source=")? != "Notarized Developer ID" {
            return Err("Gatekeeper did not confirm notarized Developer ID authority.".into());
        }
    }
    // Archive only the app. Workspaces, external model caches and source archives
    // cannot enter the submission through a broad parent-directory compression.
    let archive = receipts.root.join(format!("Bloom-{}.zip", result.edition));
    receipts.command(
        "archive",
        "/usr/bin/ditto",
        &[
            "-c".into(),
            "-k".into(),
            "--sequesterRsrc".into(),
            "--keepParent".into(),
            copy.as_os_str().into(),
            archive.as_os_str().into(),
        ],
    )?;
    save(
        &receipts.root.join("archive.json"),
        &serde_json::to_vec_pretty(&json!({
            "stage": stage.to_string_lossy(), "file": archive.file_name().map(|v| v.to_string_lossy()), "sha256": hash(&archive)?,
            "apple_submission_performed": false, "installation_and_relaunch_qualified": false,
        }))?,
    )?;
    Ok(result)
}

fn run() -> Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() < 3
        || !matches!(args[0].to_str(), Some("inspect" | "sign" | "archive"))
        || args.len()
            != match args[0].to_str() {
                Some("sign") => 6,
                Some("archive") => 4,
                _ => 3,
            }
    {
        return Err("Use: bloom-delivery inspect APP NEW_EVIDENCE; sign APP BUILD_EVIDENCE development|distribution IDENTITY ENTITLEMENTS; archive APP NEW_EVIDENCE submission|notarized. All paths must be absolute.".into());
    }
    let app = fs::canonicalize(absolute(&args[1])?)?;
    let out = absolute(&args[2])?;
    // Canonicalize the parent before checking containment, including symlink aliases.
    let parent = out.parent().ok_or("Missing evidence parent.")?;
    let canonical_out =
        fs::canonicalize(parent)?.join(out.file_name().ok_or("Missing evidence name.")?);
    if canonical_out.starts_with(&app) {
        return Err("Evidence must be outside the signed bundle.".into());
    }
    if args[0] == "sign" {
        if !out.is_dir()
            || app.parent() != Some(canonical_out.as_path())
            || out.join("executable.sha256").exists()
            || out.join("files.sha256").exists()
        {
            return Err(
                "Signing requires its fresh build directory, never a completed or sealed delivery."
                    .into(),
            );
        }
    } else {
        fs::create_dir(&out)?;
    }
    let receipts = Receipts {
        root: out.join("delivery"),
    };
    fs::create_dir(&receipts.root)?;
    save(
        &receipts.root.join("operation.json"),
        &serde_json::to_vec_pretty(&json!({
            "operation": args[0].to_string_lossy(), "bundle": app, "tool_sha256": hash(&env::current_exe()?)?,
            "apple_submission_performed": false, "application_launched": false,
        }))?,
    )?;
    let result = match args[0].to_str() {
        Some("sign") => sign(&app, &receipts, &args[3..]),
        Some("archive") => archive(&app, &receipts, &args[3]),
        _ => inspect(&app, &receipts),
    };
    let terminal = match &result {
        Ok(inspection) => {
            json!({"status": "complete", "inspection": inspection, "distribution_qualified": false})
        }
        Err(error) => {
            json!({"status": "failed", "error": error.to_string(), "distribution_qualified": false})
        }
    };
    save(
        &receipts.root.join("result.json"),
        &serde_json::to_vec_pretty(&terminal)?,
    )?;
    result?;
    println!("Delivery evidence retained at {}", receipts.root.display());
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("Bloom delivery: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn development_signatures_and_local_signed_times_do_not_admit_release() {
        assert_eq!(
            preparation_issues("Apple Development: Example", None).len(),
            2
        );
        assert_eq!(
            preparation_issues("Apple Development: Example", Some("Oct 5")).len(),
            1
        );
        assert_eq!(
            preparation_issues("Developer ID Application: Example", None).len(),
            1
        );
        assert_eq!(
            preparation_issues("Developer ID Application: Example", Some("none")).len(),
            1
        );
        assert!(preparation_issues("Developer ID Application: Example", Some("Oct 5")).is_empty());
        assert!(!Profile::Distribution.accepts("Developer ID Installer: Example"));
    }

    #[test]
    fn unrelated_entitlements_and_boolean_lookalikes_are_rejected() {
        for value in [
            json!({}),
            json!({"com.apple.security.device.audio-input": 1}),
            json!({"com.apple.security.device.audio-input": "true"}),
            json!({"com.apple.security.device.audio-input": true, "com.apple.security.get-task-allow": false}),
        ] {
            assert!(check_entitlements(&value).is_err());
        }
        assert!(
            check_entitlements(&json!({"com.apple.security.device.audio-input": true})).is_ok()
        );
    }

    #[test]
    fn signing_fields_do_not_include_executable_paths_or_accept_ambiguity() {
        let output = "designated => identifier \"com.delysis.Bloom\"\nExecutable=/other/path\n";
        assert_eq!(
            field(output, "designated => ").expect("requirement"),
            "identifier \"com.delysis.Bloom\""
        );
        assert!(field("Timestamp=one\nTimestamp=two", "Timestamp=").is_err());
        assert!(field("Timestamp=", "Timestamp=").is_err());
        assert!(field("Signed Time=now", "Timestamp=").is_err());
    }

    #[test]
    fn runtime_is_a_native_flag_bit_not_a_display_label() {
        assert!(runtime_enabled("v=20500 flags=0x10000(runtime)").expect("flags"));
        assert!(runtime_enabled("v=20500 flags=0x12000(runtime,other)").expect("flags"));
        assert!(!runtime_enabled("v=20500 flags=0x0(runtime)").expect("flags"));
        assert!(runtime_enabled("v=20500 flags=runtime").is_err());
    }

    #[test]
    fn nested_code_and_external_resource_links_are_refused() {
        let app = env::temp_dir().join(format!("bloom-delivery-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(app.join("Contents/MacOS")).expect("fixture");
        fs::write(app.join("Contents/MacOS/Bloom"), [0xcf, 0xfa, 0xed, 0xfe]).expect("fixture");
        assert!(check_bundle_files(&app).is_ok());
        let nested = app.join("Contents/helper");
        fs::write(&nested, [0xcf, 0xfa, 0xed, 0xfe]).expect("nested fixture");
        assert!(check_bundle_files(&app).is_err());
        fs::remove_file(nested).expect("remove nested fixture");
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("/outside-the-bundle", app.join("Contents/link"))
                .expect("link fixture");
            assert!(check_bundle_files(&app).is_err());
        }
        fs::remove_dir_all(app).expect("remove fixture");
    }
}
