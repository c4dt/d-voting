# D-voting scripts

Run every command in this document from the repository root.

## Local environment

The following scripts configure and run D-voting directly on the local
machine. Run them in this order:

- `run_local.sh` sets up a complete system with four nodes, the database, the
  authentication server, and the frontend. Only the database runs in Docker;
  the other services run directly on the machine. This allows easier debugging
  and faster testing of the authentication server and frontend. Debugging DELA
  still requires restarting the complete environment.
- `local_proxies.sh` must be run once after `run_local.sh`.
- `local_forms.sh` creates a new form and prints its ID.

```bash
./scripts/run_local.sh
./scripts/local_proxies.sh
./scripts/local_forms.sh
```

The following helper is only called by the other scripts:

- `local_login.sh` logs into the frontend and stores the cookie.

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

## Local system tests

The focused tests in `scripts/system-tests` expect an initialized D-voting
environment with development login enabled. Run the complete suite with:

```bash
./scripts/system-tests/run_all.sh
```

The suite covers proxies, forms and configuration boundaries, access control,
DKG, voting validation, shuffling, a complete election lifecycle, and a load
test with 300 votes by default. Each test script documents its environment
options at the top and can be run independently, for example:

```bash
VOTES=513 BATCH_SIZE=20 ./scripts/system-tests/load.sh
NESTING_DEPTH=16 ./scripts/system-tests/form_configurations.sh
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
