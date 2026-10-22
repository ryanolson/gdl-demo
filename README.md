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
timeout 60 cargo test
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

## Build and run with Docker Compose

Run these commands from this repository. Use `cargo-gdl` from the pinned GDL revision and a host with Docker Compose.

Generate the deployment bundle:

```bash
cargo gdl compose --spec deploy.toml --out deployment
```

`deploy.toml` imports both node packages from this repository at Git commit `a6c607ba48b4edea33f684699c8701bbdd543207`. It pins the runtime to the same public GDL core revision as the node crates. The bundle contains segment crates, Dockerfiles, runtime TOML, a discovery hub, and `compose.yaml`.

Keep `deployment/compose.yaml` first so the receiver's build context resolves to this repository:

```bash
docker compose -f deployment/compose.yaml -f accounting.compose.yaml up --build -d
```

The `accounting` service runs the generated segment that hosts `UsageTap`. The separate `ledger` service runs the mock HTTP receiver. The tap sends accounting events to `http://ledger:8091/usage` on the Compose network.

| Service | Application endpoint on the host | System endpoint on the host |
| --- | --- | --- |
| `front` | `http://127.0.0.1:8082/generate` | `http://127.0.0.1:9090` |
| `engine` | None | `http://127.0.0.1:9091` |
| `accounting` | None | `http://127.0.0.1:9092` |
| `ledger` | `http://127.0.0.1:8091/usage` | None |

The segment containers use system port 9090 internally. The host mappings identify each segment separately. All published host ports bind to loopback.

Wait for all three segment health endpoints to return HTTP 200:

```bash
curl --fail --max-time 5 http://127.0.0.1:9090/health
curl --fail --max-time 5 http://127.0.0.1:9091/health
curl --fail --max-time 5 http://127.0.0.1:9092/health
```

Read the receiver's readiness signal:

```bash
docker compose -f deployment/compose.yaml -f accounting.compose.yaml logs ledger
```

The receiver prints `Mock accounting receiver: http://0.0.0.0:8091/usage` after it binds its listener. Wait for this line before the request. Container startup alone does not establish graph readiness. The receiver has no `GET /health` endpoint.

Send the fixture request:

```bash
curl --fail --max-time 10 -N http://127.0.0.1:8082/generate \
  -H 'Content-Type: application/json' \
  -d '{"text":"hello graph"}'
```

The deployment's graph options select uppercase text and the `film-engine` model label:

```json
{"kind":"text","index":0,"text":"HELLO"}
{"kind":"text","index":1,"text":"GRAPH"}
{"kind":"usage","model":"film-engine","input_tokens":2,"output_tokens":2}
```

Read the ledger logs again to see the accepted usage event. Its tenant is `acme-film`. The event carries the same terminal usage values as the response.

Read the actual engine and tap metrics:

```bash
curl --fail --max-time 5 http://127.0.0.1:9091/metrics
curl --fail --max-time 5 http://127.0.0.1:9092/metrics
```

The node counters have the default `dynamo_component_` prefix. A fresh deployment's first successful two-word request increments `mock_requests_total` by one and `mock_chunks_total` by three. The tap increments `accounting_events_total` by one after the receiver accepts its POST. `dynamo_endpoint` identifies the node. `dynamo_component`, `dynamo_namespace`, and `worker_id` identify the running deployment and process.

Stop this deployment:

```bash
docker compose -f deployment/compose.yaml -f accounting.compose.yaml down
```

### Configuration follows the node contract

The graph owns `Engine.model`, `Engine.uppercase`, `UsageTap.tenant`, and `UsageTap.enabled`. The generated binary carries these values in `Binary::GRAPH_CONFIG`. They do not automatically become entries in runtime `config.toml`. A conflicting runtime override prevents startup.

Runtime-only values remain explicit per segment. The frontend's `listen` address and tap's `accounting_url` come from the deployment settings. The Compose bundle writes those settings to each segment's `config.toml` and includes that file in its image. After a placement change, supply runtime-only values to the destination segment explicitly.

Metric definitions also belong to the node. The node name remains its `dynamo_endpoint` label across placements. New processes have new worker identities and fresh counters. The generated deployment currently uses Compose and runtime TOML. DGD and ConfigMap rendering remain future targets.

### Validation status

The eight node tests run natively. Compose generation succeeded with the pinned public sources. The accounting binary also accepts a fixture POST and prints its event in a native run. Docker is unavailable on the preparation host, so container builds and Compose execution remain untested. The composer's Build and apply requires Docker on its host and the explicit `--docker` option.
