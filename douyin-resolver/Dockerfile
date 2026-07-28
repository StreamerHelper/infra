FROM rust:1.90.0-bookworm AS builder
WORKDIR /build

COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --locked --release

FROM debian:bookworm-slim AS runtime

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /build/target/release/douyin-resolver /usr/local/bin/douyin-resolver
COPY LICENSE THIRD_PARTY_NOTICES.md /usr/share/doc/douyin-resolver/

ENV DOUYIN_RESOLVER_BIND=0.0.0.0:7100
EXPOSE 7100
USER 10001:10001
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/douyin-resolver", "healthcheck"]

ENTRYPOINT ["/usr/local/bin/douyin-resolver"]
