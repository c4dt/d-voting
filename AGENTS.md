# AGENTS.md

Guidance for AI coding agents working on the D-Voting repository. It sums up
the layout, the commands to build, test and lint each part, and the
conventions to follow. Human contributors may find it useful too.

## Project overview

D-Voting is an e-voting platform built on top of the
[DELA blockchain](https://github.com/c4dt/dela). It is composed of:

- a blockchain node written in Go (root module `github.com/c4dt/d-voting`),
  running the `evoting` smart contract, the DKG and Neff shuffle services and
  an HTTP proxy,
- a web frontend (React) and a web backend (Express + TypeScript) under `web/`,
- a Docker Compose environment to run a small network locally.

The Go module depends on the `c4dt` forks of `go.dedis.ch/dela` and
`go.dedis.ch/dela-apps` (see the `replace` directives in `go.mod`).

## Repository layout

| Path | Content |
| --- | --- |
| `cli/` | Node CLIs: `dvoting` (main node), `cosipbftcontroller`, `postinstall` |
| `contracts/evoting/` | The evoting smart contract: types, controller and CLI commands |
| `proxy/` | HTTP handlers (REST API) exposing the node: elections, DKG, shuffle, transaction manager |
| `services/` | `dkg/pedersen` and `shuffle/neff` protocol implementations |
| `internal/` | Internal packages: testing helpers, tracing, `mcheck` (custom `go vet` tool) |
| `metrics/` | Prometheus collectors and the metrics controller CLI |
| `integration/` | Integration tests (long-running, spin up a node network) |
| `web/frontend/` | React app served to voters and administrators |
| `web/backend/` | Express server handling authentication (Microsoft Entra) and authorization (casbin) |
| `docker-compose/`, `Dockerfiles/`, `scripts/` | Docker environment and helper scripts |
| `docs/` | Documentation: REST API, ballot encoding, message signatures, ... |

## Go (root module)

Go >= 1.25 is required.

| Command | Description |
| --- | --- |
| `make check` | Lint + vet + all unit tests (excluding `integration/`); run it before pushing |
| `make lint` | `go mod tidy` + [staticcheck](https://staticcheck.dev) (v0.7.0) |
| `make vet` | Custom `go vet` checks via `internal/mcheck` (`-commentLen`, `-ifInit`) |
| `go test $(go list ./... \| grep -v /integration)` | Unit tests only |
| `go test -timeout 10m -run TestIntegration ./integration/...` | Full integration scenario, as run in CI |

CI runs `make vet` and the unit tests with coverage
(`.github/workflows/go_test.yml`), plus the integration scenarios
`TestIntegration`, `TestBadVote`, `TestRevote` and `TestCrash`
(`.github/workflows/go_integration_tests.yml`).

Style:

- keep the code `gofmt`-clean and free of staticcheck warnings,
- `mcheck` enforces comment rules, so document exported symbols and keep
  comments reasonable in length,
- errors are wrapped with `github.com/golang.org/x/xerrors`, follow the
  existing pattern.

## Web frontend (`web/frontend/`)

| Command | Description |
| --- | --- |
| `npm install` | Install dependencies |
| `npm start` | Dev server with a mocked API (msw), no backend needed |
| `REACT_APP_NOMOCK=on npm start` | Dev server against the real backend |
| `npm run eslint` / `npm run eslint-fix` | Lint (or auto-fix) `src/` and `tests/` |
| `npm run prettier-check` / `npm run prettier` | Check (or fix) the formatting |
| `npm test` | Unit tests (Jest via react-scripts) |
| `npx playwright test` | E2E tests in `tests/`; the frontend must run at `http://127.0.0.1:3000` |

Playwright reads the root `.env` file (create it from `.env.example`), which
sets `FRONT_END_URL=http://127.0.0.1:3000`. CI lints with ESLint and Prettier
on Node 16 (`.github/workflows/web_frontend_lint.yml`).

## Web backend (`web/backend/`)

| Command | Description |
| --- | --- |
| `npm install` | Install dependencies |
| `cp config.env.template config.env` | Create the configuration (first time only) |
| `npm run start-dev` | Dev server with `nodemon` |
| `npm run eslint` / `npm run eslint-fix` | Lint (or auto-fix) |
| `npm run prettier-check` / `npm run prettier` | Check (or fix) the formatting |

There are currently no backend unit tests (`npm test` is a placeholder). CI
lints with ESLint and Prettier on Node 16, after copying
`config.env.template` to `config.env`
(`.github/workflows/web_backend_lint.yml`).

## Docker environment

From the repository root (see `README.docker.md` and `scripts/README.md`):

| Command | Description |
| --- | --- |
| `cp .env.example .env` | Create the environment file (first time only) |
| `./scripts/run_docker.sh` | Build the images, start the containers, init DELA, add admin accounts and proxies |
| `./scripts/run_docker.sh teardown` | Stop the containers and reset the whole environment |

The `init_dela` subcommand must only be run exactly once per environment.

## Conventions

- Branches are named after the issue they address, e.g. `262-create-agents-md`.
- Commit messages are short and imperative; semantic commit messages
  (`feat:`, `fix:`, `docs:`, `chore:`, ...) are welcome.
- Pull requests follow `.github/pull_request_template.md`: describe the
  changes, self-assign, start in draft mode, and link the related issue with a
  [closing keyword](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/using-keywords-in-issues-and-pull-requests#linking-a-pull-request-to-an-issue).
- Keep `README.md` and this file up to date when commands, layout or
  conventions change.
