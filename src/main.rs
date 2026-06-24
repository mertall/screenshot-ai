//! screenshot-ai watcher (Rust port of screenshot-ai.sh).
//!
//! Polls the staging dir for new screenshots, asks "Using this for AI?" via a
//! native macOS dialog, moves the file to the keep dir, and — if the user
//! opted in — schedules a detached auto-delete after TTL seconds.
//!
//! Pure std, no external crates: polling instead of FSEvents keeps the build
//! dependency-free and the behaviour identical to the original bash watcher.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

struct Config {
    pending_dir: PathBuf,
    keep_dir: PathBuf,
    ttl_secs: u64,
    poll: Duration,
    settle: Duration,
}

fn home() -> PathBuf {
    PathBuf::from(env::var("HOME").expect("HOME not set"))
}

fn env_u64(key: &str, default: u64) -> u64 {
    env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

impl Config {
    fn from_env() -> Config {
        let base = home().join(".screenshot-ai");
        Config {
            pending_dir: base.join("pending"),
            keep_dir: env::var("SCREENSHOT_AI_KEEP_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| home().join("Desktop")),
            ttl_secs: env_u64("SCREENSHOT_AI_TTL", 300),
            poll: Duration::from_millis(env_u64("SCREENSHOT_AI_POLL_MS", 100)),
            settle: Duration::from_millis(env_u64("SCREENSHOT_AI_SETTLE_MS", 80)),
        }
    }
}

fn is_image(path: &Path) -> bool {
    match path.extension().and_then(|e| e.to_str()) {
        Some(ext) => {
            let e = ext.to_ascii_lowercase();
            e == "png" || e == "jpg"
        }
        None => false,
    }
}

/// Split a filename into (stem, ext), matching bash's `${n%.*}` / `${n##*.}`.
/// "a.png" -> ("a", "png"); "no-ext" -> ("no-ext", "").
fn split_name(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i + 1..]),
        _ => (name, ""),
    }
}

/// Wait until the file stops growing (two equal, non-zero size samples) or a
/// 4s cap elapses, so we never prompt on a half-written capture.
fn wait_for_settle(path: &Path, settle: Duration) {
    let mut last: i64 = -1;
    let deadline = Instant::now() + Duration::from_secs(4);
    while Instant::now() < deadline {
        let size = fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0);
        if size > 0 && size == last {
            return;
        }
        last = size;
        thread::sleep(settle);
    }
}

/// Move `src` into `dst_dir` under `name`, appending " (N)" if a file with that
/// name already exists so we never clobber an existing capture.
fn move_to_keep(src: &Path, dst_dir: &Path, name: &str) -> std::io::Result<PathBuf> {
    let (stem, ext) = split_name(name);
    let mut target = dst_dir.join(name);
    let mut i = 1;
    while target.exists() {
        let candidate = if ext.is_empty() {
            format!("{stem} ({i})")
        } else {
            format!("{stem} ({i}).{ext}")
        };
        target = dst_dir.join(candidate);
        i += 1;
    }
    // Same volume (both under $HOME) so rename is atomic; fall back to copy+rm
    // if it ever crosses a filesystem boundary.
    if fs::rename(src, &target).is_err() {
        fs::copy(src, &target)?;
        fs::remove_file(src)?;
    }
    Ok(target)
}

fn osascript(script: &str) -> Option<String> {
    Command::new("osascript")
        .arg("-e")
        .arg(script)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// Show the native dialog and return the clicked button. A test seam
/// (SCREENSHOT_AI_TEST_CHOICE) bypasses osascript so the pipeline is testable.
fn prompt_user(cfg: &Config, name: &str) -> String {
    if let Ok(choice) = env::var("SCREENSHOT_AI_TEST_CHOICE") {
        return choice;
    }
    let minutes = cfg.ttl_secs / 60;
    let esc = name.replace('"', "\\\"");
    // No "with icon <image>": using the raw screenshot decodes a multi-MB
    // Retina PNG and adds ~2.5s of lag. A stock "note" icon is instant.
    let script = format!(
        r#"tell application "System Events"
activate
try
set theDialog to (display dialog "Screenshot: {esc}" & return & return & "Using this for AI?" & return & "(If yes, it will auto-delete in {minutes} min.)" buttons {{"Keep", "Yes — auto-delete"}} default button "Yes — auto-delete" with title "Screenshot AI" with icon note giving up after 600)
return button returned of theDialog
on error
return "Keep"
end try
end tell"#
    );
    osascript(&script).filter(|s| !s.is_empty()).unwrap_or_else(|| "Keep".to_string())
}

fn notify(msg: &str) {
    let esc = msg.replace('"', "\\\"");
    let _ = Command::new("osascript")
        .arg("-e")
        .arg(format!(
            "display notification \"{esc}\" with title \"Screenshot AI\""
        ))
        .spawn();
}

/// Detached sleep+rm so the timer survives this process restarting.
fn schedule_delete(path: &Path, ttl_secs: u64) {
    let esc = path.to_string_lossy().replace('"', "\\\"");
    let _ = Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("sleep {ttl_secs} && rm -f \"{esc}\""))
        .spawn();
}

fn handle_screenshot(cfg: &Config, src: &Path) {
    let name = match src.file_name().and_then(|n| n.to_str()) {
        Some(n) => n.to_string(),
        None => return,
    };
    wait_for_settle(src, cfg.settle);
    let choice = prompt_user(cfg, &name);

    let final_path = match move_to_keep(src, &cfg.keep_dir, &name) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("failed to move {}: {e}", src.display());
            return;
        }
    };

    if choice == "Yes — auto-delete" {
        schedule_delete(&final_path, cfg.ttl_secs);
        notify(&format!("Auto-delete in {} min: {name}", cfg.ttl_secs / 60));
        eprintln!(
            "AI mode: {} will be deleted in {}s",
            final_path.display(),
            cfg.ttl_secs
        );
    } else {
        eprintln!("Kept: {}", final_path.display());
    }
}

fn main() {
    let cfg = Config::from_env();
    fs::create_dir_all(&cfg.pending_dir).ok();
    fs::create_dir_all(&cfg.keep_dir).ok();
    eprintln!("screenshot-ai watching {}", cfg.pending_dir.display());

    // Single sequential watcher: the blocking dialog inside handle_screenshot
    // means a file is only ever processed once — no claim/lock needed.
    loop {
        if let Ok(entries) = fs::read_dir(&cfg.pending_dir) {
            let mut files: Vec<PathBuf> = entries
                .flatten()
                .map(|e| e.path())
                .filter(|p| is_image(p))
                .collect();
            files.sort();
            for f in &files {
                handle_screenshot(&cfg, f);
            }
        }
        thread::sleep(cfg.poll);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_name_cases() {
        assert_eq!(split_name("a.png"), ("a", "png"));
        assert_eq!(split_name("Screen Shot.jpg"), ("Screen Shot", "jpg"));
        assert_eq!(split_name("no-ext"), ("no-ext", ""));
        assert_eq!(split_name(".hidden"), (".hidden", "")); // leading dot only
    }

    #[test]
    fn is_image_cases() {
        assert!(is_image(Path::new("/x/a.png")));
        assert!(is_image(Path::new("/x/a.PNG")));
        assert!(is_image(Path::new("/x/a.jpg")));
        assert!(!is_image(Path::new("/x/a.heic")));
        assert!(!is_image(Path::new("/x/a")));
    }

    #[test]
    fn move_to_keep_dedups_without_clobber() {
        let dir = env::temp_dir().join(format!("ssai-test-{}", std::process::id()));
        let keep = dir.join("keep");
        let stage = dir.join("stage");
        fs::create_dir_all(&keep).unwrap();
        fs::create_dir_all(&stage).unwrap();

        // pre-existing file in keep dir
        fs::write(keep.join("c.png"), b"ORIGINAL").unwrap();

        let src = stage.join("c.png");
        fs::write(&src, b"NEW").unwrap();
        let moved = move_to_keep(&src, &keep, "c.png").unwrap();

        assert_eq!(fs::read(keep.join("c.png")).unwrap(), b"ORIGINAL");
        assert_eq!(moved, keep.join("c (1).png"));
        assert_eq!(fs::read(&moved).unwrap(), b"NEW");
        assert!(!src.exists());

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn settle_returns_on_stable_file() {
        let f = env::temp_dir().join(format!("ssai-settle-{}.png", std::process::id()));
        fs::write(&f, b"PNGDATA").unwrap();
        let t = Instant::now();
        wait_for_settle(&f, Duration::from_millis(20));
        assert!(t.elapsed() < Duration::from_secs(1));
        fs::remove_file(&f).ok();
    }

    #[test]
    fn handle_screenshot_auto_delete_moves_then_removes() {
        let dir = env::temp_dir().join(format!("ssai-flow-{}", std::process::id()));
        let keep = dir.join("keep");
        let stage = dir.join("stage");
        fs::create_dir_all(&keep).unwrap();
        fs::create_dir_all(&stage).unwrap();

        let cfg = Config {
            pending_dir: stage.clone(),
            keep_dir: keep.clone(),
            ttl_secs: 1,
            poll: Duration::from_millis(50),
            settle: Duration::from_millis(20),
        };
        let src = stage.join("a.png");
        fs::write(&src, b"PNGDATA").unwrap();

        env::set_var("SCREENSHOT_AI_TEST_CHOICE", "Yes — auto-delete");
        handle_screenshot(&cfg, &src);
        env::remove_var("SCREENSHOT_AI_TEST_CHOICE");

        let landed = keep.join("a.png");
        assert!(landed.exists(), "should land in keep dir");
        assert!(!src.exists(), "should leave staging");

        thread::sleep(Duration::from_millis(1800)); // ttl 1s + buffer
        assert!(!landed.exists(), "should auto-delete after ttl");

        fs::remove_dir_all(&dir).ok();
    }
}
