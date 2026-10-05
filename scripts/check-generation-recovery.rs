//! Compile with rustc. Kills only the child it launches, after a real checkpoint.
use std::{
    env, fs,
    path::Path,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if !(3..=4).contains(&args.len()) {
        return Err(
            "Use driver ABSOLUTE_BUNDLE consultation|writing NEW_ABSOLUTE_EVIDENCE [cancel]".into(),
        );
    }
    let bundle = Path::new(&args[0]);
    let purpose = args[1].to_str().ok_or("Invalid model purpose")?;
    let evidence = Path::new(&args[2]);
    let graceful = args.get(3).is_some_and(|value| value == "cancel");
    if !bundle.is_absolute()
        || !evidence.is_absolute()
        || evidence.exists()
        || !["consultation", "writing"].contains(&purpose)
        || (args.len() == 4 && !graceful)
    {
        return Err("Invalid bundle, purpose, or existing evidence directory".into());
    }
    let executable = bundle.join("Contents/MacOS/Bloom");
    let mut child = Command::new("/usr/bin/sandbox-exec")
        .args(["-p", "(version 1)(allow default)(deny network*)"])
        .arg(&executable)
        .args([
            "--generation-recovery-smoke",
            if graceful { "cancel" } else { "write" },
            "--purpose",
            purpose,
            "--evidence",
        ])
        .arg(evidence)
        .stdin(Stdio::null())
        .spawn()?;
    let pid = child.id();
    let started = Instant::now();
    let marker = evidence.join("kill-ready.json");
    loop {
        if let Some(status) = child.try_wait()? {
            if graceful && status.success() {
                fs::write(
                    evidence.join("native-cancel-driver.json"),
                    format!(
                        "{{\"pid\":{pid},\"os_network_denied\":true,\"purpose\":{purpose:?}}}\n"
                    ),
                )?;
                println!(
                    "Passed native {purpose} cancellation: {}",
                    evidence.display()
                );
                return Ok(());
            }
            return Err(format!("Writer ended before forced interruption: {status}").into());
        }
        if marker.exists() && !graceful {
            break;
        }
        if started.elapsed() > Duration::from_secs(260) {
            child.kill()?;
            child.wait()?;
            return Err("Writer timed out; failed attempt retained".into());
        }
        thread::sleep(Duration::from_millis(25));
    }
    child.kill()?;
    let status = child.wait()?;
    use std::os::unix::process::ExitStatusExt;
    if status.signal() != Some(9) {
        return Err("Writer did not terminate through SIGKILL".into());
    }
    fs::write(
        evidence.join("forced-interruption.json"),
        format!(
        "{{\"pid\":{pid},\"signal\":9,\"checkpoint_barrier\":\"SIGSTOP\",\"os_network_denied\":true,\"purpose\":{purpose:?}}}\n"
        ),
    )?;
    let status = Command::new("/usr/bin/sandbox-exec")
        .args(["-p", "(version 1)(allow default)(deny network*)"])
        .arg(&executable)
        .args([
            "--generation-recovery-smoke",
            "recover",
            "--purpose",
            purpose,
            "--evidence",
        ])
        .arg(evidence)
        .stdin(Stdio::null())
        .status()?;
    if !status.success() {
        return Err(format!("Recovery failed: {status}; all evidence retained").into());
    }
    println!(
        "Passed forced {purpose} interruption: {}",
        evidence.display()
    );
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("Recovery driver failed: {error}");
        std::process::exit(1);
    }
}
