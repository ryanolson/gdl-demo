FROM rust:1.93.1-slim-bookworm AS build

# The locked workspace fetches GDL from its pinned public Git revision.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY gdl-demo-nodes ./gdl-demo-nodes
COPY acme-gdl-nodes ./acme-gdl-nodes
RUN cargo build --locked --release -p acme-gdl-nodes --bin accounting

FROM debian:bookworm-slim
COPY --from=build /build/target/release/accounting /usr/local/bin/accounting
EXPOSE 8091
ENTRYPOINT ["/usr/local/bin/accounting", "0.0.0.0:8091"]
