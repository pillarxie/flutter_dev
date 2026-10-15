//! Run the built binary with a minimal desktop PATH to verify tool discovery.
use anyhow::{bail, Context, Result};
use flutter_dev_core::process::OwnedProcess;
use std::{collections::HashMap, path::Path, time::Duration};
use tokio::io::AsyncReadExt;

#[tokio::main]
async fn main() -> Result<()> {
    let inherited = std::process::Command::new("/usr/bin/which")
        .arg("pod")
        .output()?;
    println!(
        "Inherited environment finds pod: {}",
        inherited.status.success()
    );
    println!(
        "Owned process pod: {}",
        probe("/usr/bin/which", &["pod"], false).await?.trim()
    );
    println!(
        "CocoaPods: {}",
        probe("pod", &["--version"], false).await?.trim()
    );
    println!(
        "Homebrew: {}",
        probe("brew", &["--version"], false).await?.trim()
    );
    if let Some(sdk) = std::env::args().nth(1) {
        let flutter = Path::new(&sdk).join("bin/flutter");
        // Doctor may exit nonzero for unrelated Android/toolchain issues.
        let doctor = probe(
            flutter.to_str().context("SDK path is not UTF-8")?,
            &["doctor", "-v"],
            true,
        )
        .await?;
        let cocoa_pods = doctor
            .lines()
            .find(|line| line.contains("CocoaPods version"))
            .context("Flutter doctor did not recognize installed CocoaPods")?;
        println!("Flutter doctor: {}", cocoa_pods.trim());
    }
    Ok(())
}

async fn probe(program: &str, args: &[&str], allow_nonzero: bool) -> Result<String> {
    let mut process = OwnedProcess::spawn(
        Path::new(program),
        &args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>(),
        None,
        &HashMap::new(),
    )?;
    let mut stdout = process
        .stdout
        .take()
        .context("missing stdout")?
        .take(1024 * 1024);
    let mut stderr = process
        .stderr
        .take()
        .context("missing stderr")?
        .take(1024 * 1024);
    let mut output = String::new();
    let mut error = String::new();
    let operation = async {
        let (out, err, status) = tokio::join!(
            stdout.read_to_string(&mut output),
            stderr.read_to_string(&mut error),
            process.wait()
        );
        out?;
        err?;
        status
    };
    let status = match tokio::time::timeout(Duration::from_secs(60), operation).await {
        Ok(status) => status?,
        Err(_) => {
            process.terminate(Duration::from_secs(2)).await?;
            bail!("{program} timed out");
        }
    };
    if !status.success() && !allow_nonzero {
        bail!("{program} failed: {error}");
    }
    Ok(output)
}
