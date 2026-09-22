use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use oura_hub::store::Store;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let token = std::env::var("OURA_HUB_TOKEN").context("OURA_HUB_TOKEN is not set")?;
    if token.len() < 16 {
        bail!("OURA_HUB_TOKEN must be at least 16 characters (try: openssl rand -hex 24)");
    }
    let bind = std::env::var("OURA_HUB_BIND").unwrap_or_else(|_| "0.0.0.0:8787".into());
    let db = PathBuf::from(std::env::var("OURA_HUB_DB").unwrap_or_else(|_| "hub.db".into()));
    // The ring replica sits next to the snapshot file unless told otherwise.
    let ring_db = std::env::var("OURA_HUB_RING_DB")
        .map(PathBuf::from)
        .unwrap_or_else(|_| db.with_file_name("oura.db"));

    let store = Store::open(&db)?;
    let ring = oura_store::Store::open(&ring_db).with_context(|| format!("opening ring replica {}", ring_db.display()))?;
    let state = oura_hub::app_state(store, ring, token);
    let app = oura_hub::router(state);

    let listener = tokio::net::TcpListener::bind(&bind).await.with_context(|| format!("binding {bind}"))?;
    tracing::info!("oura-hub listening on {bind}, snapshots {}, ring replica {}", db.display(), ring_db.display());
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            // podman and docker stop with SIGTERM; a terminal sends SIGINT.
            let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("SIGTERM handler");
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = term.recv() => {}
            }
        })
        .await?;
    Ok(())
}
