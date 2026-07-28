use axum::{
    Json, Router,
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode, header::CONTENT_TYPE},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use biliup::downloader::live::{
    Douyin, LiveCredentials, LiveOptions, LivePlugin, LiveRequest, LiveStatus,
};
use reqwest::{Client, Url};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    env,
    hash::{Hash, Hasher},
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, RwLock, Semaphore};

pub const BILIUP_COMMIT: &str = "adf6a1c03be9f777a76c8c501038c27f3d90a097";
const DEFAULT_BIND: &str = "127.0.0.1:7100";
const DEFAULT_TIMEOUT_MS: u64 = 20_000;
const DEFAULT_MAX_CONCURRENCY: usize = 8;
const PERMIT_WAIT_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_REQUEST_BYTES: usize = 4 * 1024;
const MAX_URL_BYTES: usize = 2 * 1024;
const MAX_CACHE_ENTRIES: usize = 256;
const LIVE_CACHE_TTL: Duration = Duration::from_secs(3);
const OFFLINE_CACHE_TTL: Duration = Duration::from_secs(5);

#[derive(Clone)]
pub struct ResolverConfig {
    bind: SocketAddr,
    upstream_timeout: Duration,
    max_concurrency: usize,
}

impl ResolverConfig {
    pub fn from_env() -> Result<Self, String> {
        let bind = env::var("DOUYIN_RESOLVER_BIND")
            .unwrap_or_else(|_| DEFAULT_BIND.to_string())
            .parse()
            .map_err(|_| "DOUYIN_RESOLVER_BIND must be a valid socket address".to_string())?;
        let timeout_ms = parse_bounded_env_u64(
            "DOUYIN_RESOLVER_TIMEOUT_MS",
            DEFAULT_TIMEOUT_MS,
            1_000,
            60_000,
        )?;
        let max_concurrency = parse_bounded_env_usize(
            "DOUYIN_RESOLVER_MAX_CONCURRENCY",
            DEFAULT_MAX_CONCURRENCY,
            1,
            32,
        )?;

        Ok(Self {
            bind,
            upstream_timeout: Duration::from_millis(timeout_ms),
            max_concurrency,
        })
    }

    pub fn bind(&self) -> SocketAddr {
        self.bind
    }

    #[cfg(test)]
    fn test_default() -> Self {
        Self {
            bind: DEFAULT_BIND.parse().expect("valid test bind address"),
            upstream_timeout: Duration::from_secs(1),
            max_concurrency: 2,
        }
    }
}

fn parse_bounded_env_u64(
    name: &str,
    default: u64,
    minimum: u64,
    maximum: u64,
) -> Result<u64, String> {
    let Some(raw) = env::var(name).ok() else {
        return Ok(default);
    };
    let value = raw
        .parse::<u64>()
        .map_err(|_| format!("{name} must be an integer"))?;
    if !(minimum..=maximum).contains(&value) {
        return Err(format!("{name} must be between {minimum} and {maximum}"));
    }
    Ok(value)
}

fn parse_bounded_env_usize(
    name: &str,
    default: usize,
    minimum: usize,
    maximum: usize,
) -> Result<usize, String> {
    let Some(raw) = env::var(name).ok() else {
        return Ok(default);
    };
    let value = raw
        .parse::<usize>()
        .map_err(|_| format!("{name} must be an integer"))?;
    if !(minimum..=maximum).contains(&value) {
        return Err(format!("{name} must be between {minimum} and {maximum}"));
    }
    Ok(value)
}

struct PluginState {
    generation: u64,
    resolver: Arc<Douyin>,
}

struct CacheEntry {
    expires_at: Instant,
    response: ResolveResponse,
}

pub struct AppState {
    config: ResolverConfig,
    client: Client,
    plugin: RwLock<PluginState>,
    concurrency: Arc<Semaphore>,
    cache: Mutex<HashMap<CacheKey, CacheEntry>>,
}

impl AppState {
    pub fn new(config: ResolverConfig) -> Result<Self, reqwest::Error> {
        let request_timeout = config
            .upstream_timeout
            .saturating_sub(Duration::from_secs(2))
            .clamp(Duration::from_secs(1), Duration::from_secs(15));
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(request_timeout)
            .pool_idle_timeout(Duration::from_secs(90))
            .build()?;

        Ok(Self {
            concurrency: Arc::new(Semaphore::new(config.max_concurrency)),
            config,
            client,
            plugin: RwLock::new(PluginState {
                generation: 0,
                resolver: Arc::new(Douyin::new()),
            }),
            cache: Mutex::new(HashMap::new()),
        })
    }

    async fn current_plugin(&self) -> (u64, Arc<Douyin>) {
        let state = self.plugin.read().await;
        (state.generation, Arc::clone(&state.resolver))
    }

    async fn rotate_plugin_if_current(&self, failed_generation: u64) {
        let mut state = self.plugin.write().await;
        if state.generation != failed_generation {
            return;
        }
        state.generation = state.generation.wrapping_add(1);
        state.resolver = Arc::new(Douyin::new());
    }

    async fn rotate_plugin(&self) {
        let mut state = self.plugin.write().await;
        state.generation = state.generation.wrapping_add(1);
        state.resolver = Arc::new(Douyin::new());
    }

    async fn get_cached(&self, key: &CacheKey) -> Option<ResolveResponse> {
        let now = Instant::now();
        let mut cache = self.cache.lock().await;
        cache.retain(|_, entry| entry.expires_at > now);
        cache.get(key).map(|entry| entry.response.clone())
    }

    async fn cache_response(&self, key: CacheKey, response: ResolveResponse) {
        let ttl = match response {
            ResolveResponse::Live { .. } => LIVE_CACHE_TTL,
            ResolveResponse::Offline { .. } => OFFLINE_CACHE_TTL,
            ResolveResponse::Unavailable { .. } => return,
        };
        let mut cache = self.cache.lock().await;
        if cache.len() >= MAX_CACHE_ENTRIES {
            cache.retain(|_, entry| entry.expires_at > Instant::now());
        }
        if cache.len() >= MAX_CACHE_ENTRIES
            && let Some(oldest_key) = cache
                .iter()
                .min_by_key(|(_, entry)| entry.expires_at)
                .map(|(key, _)| key.clone())
        {
            cache.remove(&oldest_key);
        }
        cache.insert(
            key,
            CacheEntry {
                expires_at: Instant::now() + ttl,
                response,
            },
        );
    }
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/v1/douyin/resolve", post(resolve))
        .with_state(state)
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "state": "ok",
        "version": env!("CARGO_PKG_VERSION"),
        "biliupCommit": BILIUP_COMMIT,
    }))
}

async fn resolve(State(state): State<Arc<AppState>>, headers: HeaderMap, body: Bytes) -> Response {
    let request = match parse_request(&headers, &body) {
        Ok(request) => request,
        Err(error) => return error.into_response(),
    };
    let cache_key = CacheKey::from(&request);
    if let Some(response) = state.get_cached(&cache_key).await {
        return (StatusCode::OK, Json(response)).into_response();
    }

    let Ok(Ok(_permit)) = tokio::time::timeout(
        PERMIT_WAIT_TIMEOUT,
        Arc::clone(&state.concurrency).acquire_owned(),
    )
    .await
    else {
        return (
            StatusCode::OK,
            Json(ResolveResponse::unavailable(
                "BUSY",
                "Resolver remained busy after a short queue wait; retry later",
            )),
        )
            .into_response();
    };

    // A request may have completed while this request waited for a permit.
    if let Some(response) = state.get_cached(&cache_key).await {
        return (StatusCode::OK, Json(response)).into_response();
    }

    let result = tokio::time::timeout(
        state.config.upstream_timeout,
        resolve_with_single_retry(&state, &request),
    )
    .await;

    let response = match result {
        Ok(Ok(response)) => response,
        Ok(Err(())) => ResolveResponse::unavailable(
            "UPSTREAM_ERROR",
            "Douyin upstream request failed; retry later",
        ),
        Err(_) => {
            state.rotate_plugin().await;
            ResolveResponse::unavailable(
                "UPSTREAM_TIMEOUT",
                "Douyin upstream request timed out; retry later",
            )
        }
    };
    state.cache_response(cache_key, response.clone()).await;
    (StatusCode::OK, Json(response)).into_response()
}

async fn resolve_with_single_retry(
    state: &AppState,
    request: &ValidatedResolveRequest,
) -> Result<ResolveResponse, ()> {
    let (generation, plugin) = state.current_plugin().await;
    match resolve_once(state, plugin, request).await {
        Ok(response) => Ok(response),
        Err(()) => {
            state.rotate_plugin_if_current(generation).await;
            let (_, fresh_plugin) = state.current_plugin().await;
            resolve_once(state, fresh_plugin, request).await
        }
    }
}

async fn resolve_once(
    state: &AppState,
    plugin: Arc<Douyin>,
    request: &ValidatedResolveRequest,
) -> Result<ResolveResponse, ()> {
    let mut options = LiveOptions::default();
    options.douyin.quality = request.quality.biliup_quality().to_string();
    options.douyin.protocol = request.protocol.biliup_protocol().to_string();
    // Biliup only exposes the resolved numeric room ID through DanmakuSource.
    // Enabling this flag builds metadata; it does not open a WebSocket.
    options.douyin.danmaku = true;

    let status = plugin
        .check_stream(LiveRequest {
            client: state.client.clone(),
            url: request.url.clone(),
            name: "streamerhelper".to_string(),
            options,
            credentials: LiveCredentials::default(),
        })
        .await
        .map_err(|_| ())?;

    Ok(match status {
        LiveStatus::Offline => ResolveResponse::Offline {
            room_id: request.fallback_room_id.clone(),
            title: None,
        },
        LiveStatus::Live { stream } => {
            let room_id = stream
                .danmaku
                .as_ref()
                .and_then(|source| source.room_id.clone())
                .or_else(|| request.fallback_room_id.clone());
            let title = non_empty(stream.title);
            let effective_quality =
                classify_effective_quality(&stream.raw_stream_url, request.quality);
            ResolveResponse::Live {
                room_id,
                title,
                stream: ResolvedStream {
                    url: stream.raw_stream_url,
                    headers: sanitize_stream_headers(stream.stream_headers),
                    effective_quality: Some(effective_quality),
                },
            }
        }
    })
}

fn parse_request(headers: &HeaderMap, body: &[u8]) -> Result<ValidatedResolveRequest, ApiError> {
    let content_type = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map(str::trim);
    if content_type != Some("application/json") {
        return Err(ApiError::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "INVALID_CONTENT_TYPE",
            "Content-Type must be application/json",
        ));
    }
    if body.len() > MAX_REQUEST_BYTES {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "REQUEST_TOO_LARGE",
            "Request body exceeds 4096 bytes",
        ));
    }
    let request: ResolveRequest = serde_json::from_slice(body).map_err(|_| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            "INVALID_JSON",
            "Request body must match the resolver schema",
        )
    })?;
    request.validate()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ResolveRequest {
    url: String,
    #[serde(default)]
    quality: Quality,
    #[serde(default)]
    protocol: Protocol,
}

impl ResolveRequest {
    fn validate(self) -> Result<ValidatedResolveRequest, ApiError> {
        if self.url.is_empty() || self.url.trim() != self.url || self.url.len() > MAX_URL_BYTES {
            return Err(invalid_url());
        }
        let mut url = Url::parse(&self.url).map_err(|_| invalid_url())?;
        if url.scheme() != "https"
            || !url.username().is_empty()
            || url.password().is_some()
            || url.port().is_some_and(|port| port != 443)
            || url.fragment().is_some()
        {
            return Err(invalid_url());
        }

        let host = url
            .host_str()
            .map(str::to_ascii_lowercase)
            .ok_or_else(invalid_url)?;
        let segments = url
            .path_segments()
            .map(|segments| {
                segments
                    .filter(|value| !value.is_empty())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let fallback_room_id = match host.as_str() {
            "live.douyin.com" => {
                if segments.len() != 1 || !valid_identifier(segments[0].trim_start_matches('+')) {
                    return Err(invalid_url());
                }
                Some(segments[0].trim_start_matches('+').to_string())
            }
            "www.douyin.com" | "m.douyin.com" => {
                if segments.len() != 2 || segments[0] != "user" || !valid_identifier(segments[1]) {
                    return Err(invalid_url());
                }
                None
            }
            "v.douyin.com" => {
                if segments.is_empty() || segments.iter().any(|value| !valid_identifier(value)) {
                    return Err(invalid_url());
                }
                None
            }
            _ => return Err(invalid_url()),
        };
        url.set_fragment(None);

        Ok(ValidatedResolveRequest {
            url: url.to_string(),
            quality: self.quality,
            protocol: self.protocol,
            fallback_room_id,
        })
    }
}

fn invalid_url() -> ApiError {
    ApiError::new(
        StatusCode::UNPROCESSABLE_ENTITY,
        "INVALID_URL",
        "Only supported Douyin live, user, or short-link HTTPS URLs are allowed",
    )
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

#[derive(Clone)]
struct ValidatedResolveRequest {
    url: String,
    quality: Quality,
    protocol: Protocol,
    fallback_room_id: Option<String>,
}

#[derive(Clone, Eq)]
struct CacheKey {
    url: String,
    quality: Quality,
    protocol: Protocol,
}

impl From<&ValidatedResolveRequest> for CacheKey {
    fn from(request: &ValidatedResolveRequest) -> Self {
        Self {
            url: request.url.clone(),
            quality: request.quality,
            protocol: request.protocol,
        }
    }
}

impl PartialEq for CacheKey {
    fn eq(&self, other: &Self) -> bool {
        self.url == other.url && self.quality == other.quality && self.protocol == other.protocol
    }
}

impl Hash for CacheKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.url.hash(state);
        self.quality.hash(state);
        self.protocol.hash(state);
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Quality {
    #[default]
    High,
    Medium,
    Low,
}

impl Quality {
    fn biliup_quality(self) -> &'static str {
        match self {
            Self::High => "origin",
            Self::Medium => "sd",
            Self::Low => "ld",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
enum Protocol {
    #[default]
    Flv,
    Hls,
}

impl Protocol {
    fn biliup_protocol(self) -> &'static str {
        match self {
            Self::Flv => "flv",
            Self::Hls => "hls",
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(tag = "state", rename_all = "lowercase")]
pub enum ResolveResponse {
    Live {
        #[serde(rename = "roomId", skip_serializing_if = "Option::is_none")]
        room_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        stream: ResolvedStream,
    },
    Offline {
        #[serde(rename = "roomId", skip_serializing_if = "Option::is_none")]
        room_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    Unavailable {
        code: String,
        message: String,
    },
}

impl ResolveResponse {
    fn unavailable(code: &str, message: &str) -> Self {
        Self::Unavailable {
            code: code.to_string(),
            message: message.to_string(),
        }
    }
}

#[derive(Clone, Serialize)]
pub struct ResolvedStream {
    url: String,
    headers: BTreeMap<String, String>,
    #[serde(rename = "effectiveQuality", skip_serializing_if = "Option::is_none")]
    effective_quality: Option<Quality>,
}

struct ApiError {
    status: StatusCode,
    response: ResolveResponse,
}

impl ApiError {
    fn new(status: StatusCode, code: &str, message: &str) -> Self {
        Self {
            status,
            response: ResolveResponse::unavailable(code, message),
        }
    }

    fn into_response(self) -> Response {
        (self.status, Json(self.response)).into_response()
    }
}

fn non_empty(value: String) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn sanitize_stream_headers(headers: HashMap<String, String>) -> BTreeMap<String, String> {
    headers
        .into_iter()
        .filter_map(|(name, value)| {
            let normalized = name.to_ascii_lowercase();
            let allowed = matches!(
                normalized.as_str(),
                "cookie" | "user-agent" | "referer" | "origin"
            );
            if !allowed
                || name.bytes().any(|byte| matches!(byte, b'\r' | b'\n'))
                || value.bytes().any(|byte| matches!(byte, b'\r' | b'\n'))
                || value.len() > 16 * 1024
            {
                return None;
            }
            Some((normalized, value))
        })
        .collect()
}

fn classify_effective_quality(url: &str, requested: Quality) -> Quality {
    let tokens = url
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|token| !token.is_empty())
        .map(str::to_ascii_lowercase)
        .collect::<Vec<_>>();
    if tokens
        .iter()
        .any(|token| matches!(token.as_str(), "ld" | "ld1" | "md" | "md1"))
    {
        return Quality::Low;
    }
    if tokens
        .iter()
        .any(|token| matches!(token.as_str(), "sd" | "sd1" | "sd2"))
    {
        return Quality::Medium;
    }
    if tokens.iter().any(|token| {
        matches!(
            token.as_str(),
            "origin" | "uhd" | "hd" | "hd1" | "hd2" | "fullhd"
        )
    }) {
        return Quality::High;
    }
    requested
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{Body, to_bytes},
        http::Request,
    };
    use serde_json::{Value, json};
    use tower::ServiceExt;

    fn validate(url: &str) -> Result<ValidatedResolveRequest, ApiError> {
        ResolveRequest {
            url: url.to_string(),
            quality: Quality::High,
            protocol: Protocol::Flv,
        }
        .validate()
    }

    #[test]
    fn validates_only_supported_douyin_urls() {
        assert!(validate("https://live.douyin.com/446034615937").is_ok());
        assert!(
            validate("https://www.douyin.com/user/MS4wLjABAAAA_test-123?from_tab_name=live")
                .is_ok()
        );
        assert!(validate("https://v.douyin.com/AbC-123/").is_ok());

        assert!(validate("http://live.douyin.com/123").is_err());
        assert!(validate("https://example.com/123").is_err());
        assert!(validate("https://user:pass@live.douyin.com/123").is_err());
        assert!(validate("https://live.douyin.com:8443/123").is_err());
        assert!(validate("https://live.douyin.com/one/two").is_err());
        assert!(validate("https://www.douyin.com/video/123").is_err());
        assert!(validate("https://live.douyin.com/123#fragment").is_err());
    }

    #[test]
    fn sanitizes_stream_headers_without_dropping_guest_cookie() {
        let headers = HashMap::from([
            ("Cookie".to_string(), "ttwid=guest".to_string()),
            ("User-Agent".to_string(), "agent".to_string()),
            (
                "Referer".to_string(),
                "https://live.douyin.com/".to_string(),
            ),
            ("X-Internal".to_string(), "drop-me".to_string()),
            ("Origin".to_string(), "bad\r\ninjected: true".to_string()),
        ]);
        let sanitized = sanitize_stream_headers(headers);
        assert_eq!(sanitized.get("cookie"), Some(&"ttwid=guest".to_string()));
        assert_eq!(sanitized.get("user-agent"), Some(&"agent".to_string()));
        assert!(!sanitized.contains_key("x-internal"));
        assert!(!sanitized.contains_key("origin"));
    }

    #[test]
    fn maps_quality_and_serializes_the_fixed_contract() {
        assert_eq!(
            classify_effective_quality("https://pull.example/stream_sd1.flv", Quality::High),
            Quality::Medium
        );
        let live = ResolveResponse::Live {
            room_id: Some("123".to_string()),
            title: Some("Live title".to_string()),
            stream: ResolvedStream {
                url: "https://pull.example/live.flv".to_string(),
                headers: BTreeMap::from([("cookie".to_string(), "ttwid=guest".to_string())]),
                effective_quality: Some(Quality::High),
            },
        };
        assert_eq!(
            serde_json::to_value(live).expect("serialize live response"),
            json!({
                "state": "live",
                "roomId": "123",
                "title": "Live title",
                "stream": {
                    "url": "https://pull.example/live.flv",
                    "headers": { "cookie": "ttwid=guest" },
                    "effectiveQuality": "high"
                }
            })
        );
        assert_eq!(
            serde_json::to_value(ResolveResponse::Offline {
                room_id: None,
                title: None,
            })
            .expect("serialize offline response"),
            json!({ "state": "offline" })
        );
        assert_eq!(
            serde_json::to_value(ResolveResponse::unavailable("BUSY", "retry later"))
                .expect("serialize unavailable response"),
            json!({
                "state": "unavailable",
                "code": "BUSY",
                "message": "retry later"
            })
        );
    }

    #[tokio::test]
    async fn health_endpoint_exposes_the_pinned_revision() {
        let state =
            Arc::new(AppState::new(ResolverConfig::test_default()).expect("build test state"));
        let response = router(state)
            .oneshot(
                Request::builder()
                    .uri("/healthz")
                    .body(Body::empty())
                    .expect("build request"),
            )
            .await
            .expect("health response");
        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), 8 * 1024)
            .await
            .expect("read health response");
        let json: Value = serde_json::from_slice(&body).expect("parse health response");
        assert_eq!(json["state"], "ok");
        assert_eq!(json["biliupCommit"], BILIUP_COMMIT);
    }

    #[tokio::test]
    async fn invalid_requests_use_the_unavailable_contract() {
        let state =
            Arc::new(AppState::new(ResolverConfig::test_default()).expect("build test state"));
        let response = router(state)
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/douyin/resolve")
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        r#"{"url":"https://example.com/room","unknown":true}"#,
                    ))
                    .expect("build request"),
            )
            .await
            .expect("invalid response");
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = to_bytes(response.into_body(), 8 * 1024)
            .await
            .expect("read invalid response");
        let json: Value = serde_json::from_slice(&body).expect("parse invalid response");
        assert_eq!(json["state"], "unavailable");
        assert_eq!(json["code"], "INVALID_JSON");
    }
}
