# D-voting scripts

Run every command in this document from the repository root.

## Docker environment

`run_docker.sh` is the recommended way to start a complete four-node D-voting
environment on Linux. It creates `.env` from `.env.example` when needed, builds
and starts the containers, initializes DELA, registers the administrator, and
registers all proxies.

```bash
./scripts/run_docker.sh
```

The initialization can also be performed step by step:

```bash
./scripts/run_docker.sh setup
./scripts/run_docker.sh init_dela
./scripts/run_docker.sh first_proxy
./scripts/run_docker.sh add_admin
./scripts/run_docker.sh other_proxies
```

Stop the environment, remove its volumes, and remove the locally built D-voting
images with:

```bash
./scripts/run_docker.sh teardown
```

## Native local environment

For development outside Docker, `scripts/local/run_local.sh` builds and starts
the four DELA nodes, PostgreSQL, backend, and frontend. It requires `asdf`, Go,
Node.js, Docker, and the other commands used by the script.

```bash
./scripts/local/run_local.sh
./scripts/local/local_proxies.sh
./scripts/local/local_forms.sh
```

`run_local.sh` also accepts `build`, `init_nodes`, `init_dela`, `init_db`,
`backend`, `frontend`, and `clean`. The `local_login.sh` and `local_vars.sh`
files are helpers sourced by the other local scripts.

## Local system tests

The focused tests in `scripts/system-tests` expect an initialized D-voting
environment with development login enabled. Run the complete suite with:

```bash
./scripts/system-tests/run_all.sh
```

The suite covers proxies, forms and configuration boundaries, access control,
DKG, voting validation, shuffling, a complete election lifecycle, and a load
test with 300 votes by default. Each `local_*.sh` test documents its environment
options at the top and can be run independently, for example:

```bash
VOTES=513 BATCH_SIZE=20 ./scripts/system-tests/local_load.sh
NESTING_DEPTH=16 ./scripts/system-tests/local_form_configurations.sh
```

Runner defaults can also be overridden:

```bash
SYSTEM_TEST_URL=http://127.0.0.1:3000 \
TEST_TIMEOUT=1200 \
LOAD_VOTES=513 \
./scripts/system-tests/run_all.sh
```

Set `RUN_LOAD=false` to omit the load test.

## Randomized stress run

`custom_fuzz.sh` repeatedly runs the focused tests with boundary values and
randomized configurations. It runs for one hour by default.

```bash
FUZZ_SECONDS=3600 ./scripts/system-tests/custom_fuzz.sh
```

Output is printed live. Per-run logs, `results.tsv`, and `failures.tsv` are
written under the `FUZZ_LOG_DIR` printed at startup. Set `FUZZ_SEED` to reproduce
an option sequence or `FUZZ_LOG_DIR` to choose a persistent results directory.
