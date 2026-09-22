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

    let store = Store::open(&db)?;
    let state = oura_hub::app_state(store, token);
    let app = oura_hub::router(state);

    let listener = tokio::net::TcpListener::bind(&bind).await.with_context(|| format!("binding {bind}"))?;
    tracing::info!("oura-hub listening on {bind}, db {}", db.display());
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
