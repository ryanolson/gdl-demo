# GDL demonstration nodes

This workspace supplies two crates for the GDL film. Both crates depend on `gdl`. Neither crate links `gdl-runtime` or velo.

| Crate | Nodes and messages |
| --- | --- |
| `gdl-demo-nodes` | `HttpFrontend`, `MockEngine`, and the `Prompt`, `Chunk`, and `Usage` wire messages |
| `acme-gdl-nodes` | Response-only `UsageTap`, marked re-exports of `Chunk` and `Usage`, and a mock accounting receiver |

`HttpFrontend` accepts `POST /generate` with a JSON `Prompt`: `{"text":"hello graph"}`. It returns an NDJSON stream of `Chunk` values. `MockEngine` emits one text chunk per whitespace-delimited word, followed by one usage chunk. These demonstration counts do not use a model tokenizer.

```json
{"kind":"text","index":0,"text":"hello"}
{"kind":"text","index":1,"text":"graph"}
{"kind":"usage","model":"mock-echo","input_tokens":2,"output_tokens":2}
```

The engine's graph settings expose `model` and `uppercase`. Its runtime settings also accept `delay_ms`. `HttpFrontend` accepts a runtime `listen` address, which defaults to `127.0.0.1:8082`.

`UsageTap` exposes graph settings for `tenant` and `enabled`. Its runtime `accounting_url` defaults to `http://127.0.0.1:8091/usage`. It forwards every input item unchanged. The first usage chunk triggers one accounting POST per response stream. Duplicate usage chunks do not trigger another POST. Missing usage and disabled accounting produce no POST.

The tap reuses one HTTP client per node. It waits for the accounting attempt before it forwards the first usage chunk. Each attempt has a one-second timeout. A failed request increments `accounting_errors_total` and leaves the response unchanged. The tap does not retry, persist events, or guarantee durable billing.

| Metric | Meaning |
| --- | --- |
| `mock_requests_total` | Requests accepted by `MockEngine` |
| `mock_chunks_total` | Emitted chunks, including usage chunks |
| `accounting_events_total` | Accounting POSTs accepted with a successful HTTP status |
| `accounting_errors_total` | Failed accounting attempts |

## Run the mock receiver

Run this command from this workspace:

```bash
cargo run -p acme-gdl-nodes --bin accounting -- 127.0.0.1:8091
```

The receiver prints each accepted `UsageEvent` as JSON. It returns HTTP 202. A known two-word response produces this event with the default tenant:

```json
{"tenant":"acme-film","usage":{"model":"mock-echo","input_tokens":2,"output_tokens":2}}
```

The graph specification, generated segments, and deployment placement select how these nodes run. The crates use relative path dependencies so the workspace also builds from a Git checkout.

## Extract the catalog

Extract each package separately. The virtual workspace root does not identify a package:

```bash
cargo gdl extract gdl-demo-nodes --catalog catalog
cargo gdl extract acme-gdl-nodes --catalog catalog
```

The composer's Message types view lists message declarations but does not display marked re-exports. The resolver still reads ACME's marked exports and preserves their reference identity. The reference messages live at the crate root so the composer can select their public canonical types.

## Check the workspace

Build the tests before the bounded run:

```bash
cargo test --no-run
timeout 60 cargo test --manifest-path examples/film/Cargo.toml
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
```

The tests cover deterministic output, known usage, graph settings, wire identity, HTTP service, and accounting success and failure. Test listeners use OS-assigned ports. Readiness comes from bound listeners and completed HTTP requests.

## GDL revision

The node crates and generated runtime use public GDL commit `deefaa92f37ef3f6e4372c7c4c16eb1eccc1ac94`. Use `cargo-gdl` from that revision. `gdl.toml` places the frontend, engine, and usage tap in separate processes. `compact.toml` places the same graph and graph settings in one process.

```bash
cargo gdl generate --spec gdl.toml --out segments
cargo gdl generate --spec compact.toml --out compact
```
