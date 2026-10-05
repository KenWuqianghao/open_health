//! Locate the repository checkout from the running binary.

use std::path::{Path, PathBuf};

/// Locate the repo root by walking up from the current dir (then the compiled-in
/// manifest dir) for a stable `marker` file, so the binary keeps working when invoked
/// from elsewhere in the checkout. Returns `None` if not found (soft-degrade callers).
pub fn repo_root(marker: &Path) -> Option<PathBuf> {
    let find = |start: &Path| -> Option<PathBuf> {
        start
            .ancestors()
            .find(|d| d.join(marker).is_file())
            .map(Path::to_path_buf)
    };
    std::env::current_dir()
        .ok()
        .and_then(|d| find(&d))
        .or_else(|| find(Path::new(env!("CARGO_MANIFEST_DIR"))))
}
