use douyin_resolver::{AppState, ResolverConfig, router};
use std::{env, process::ExitCode, sync::Arc, time::Duration};

#[tokio::main]
async fn main() -> ExitCode {
    if env::args().nth(1).as_deref() == Some("healthcheck") {
        return healthcheck().await;
    }
    match serve().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("douyin-resolver failed: {message}");
            ExitCode::FAILURE
        }
    }
}

async fn serve() -> Result<(), String> {
    let config = ResolverConfig::from_env()?;
    let bind = config.bind();
    let state =
        Arc::new(AppState::new(config).map_err(|_| "failed to build HTTP client".to_string())?);
    let listener = tokio::net::TcpListener::bind(bind)
        .await
        .map_err(|_| format!("failed to bind {bind}"))?;
    eprintln!(
        "douyin-resolver {} listening on {}; biliup={}",
        env!("CARGO_PKG_VERSION"),
        bind,
        douyin_resolver::BILIUP_COMMIT
    );
    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|_| "HTTP server stopped unexpectedly".to_string())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("install SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

async fn healthcheck() -> ExitCode {
    let url = env::var("DOUYIN_RESOLVER_HEALTH_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:7100/healthz".to_string());
    let client = match reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(1))
        .timeout(Duration::from_secs(2))
        .build()
    {
        Ok(client) => client,
        Err(_) => return ExitCode::FAILURE,
    };
    match client.get(url).send().await {
        Ok(response) if response.status().is_success() => ExitCode::SUCCESS,
        _ => ExitCode::FAILURE,
    }
}
