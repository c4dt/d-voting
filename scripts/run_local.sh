#!/bin/bash -e
# This puts all the different steps of initializing a Dela d-voting network into one shell script.
# This can be used for development by calling the script and then testing the result locally.
# The script must be called from the root of the github tree, else it returns an error.
# If the script is called with `./scripts/run_local.sh clean`, it stops all services.
# For development, the calls to the different parts can be adjusted, e.g., comment all but
# `start_backend` to only restart the backend.

if [[ $(git rev-parse --show-toplevel) != $(pwd) ]]; then
  echo "ERROR: This script must be started from the root of the git repo"
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
. "$SCRIPT_DIR/local_vars.sh"

asdf_shell() {
  if ! asdf list "$1" | grep -wq "$2"; then
    asdf install "$1" "$2"
  fi
  asdf local "$1" "$2"
}

if [ "$DEVBOX_SHELL_ENABLED" != "1" ]; then
  asdf_shell nodejs 16.20.2
  asdf_shell golang 1.21.0
fi

mkdir -p nodes
export GOBIN=$(pwd)/bin
PATH="$PATH":"$GOBIN"

function clean_dela() {
  rm -rf bin/
}

function build_dela() {
  echo "Building dela-node"
  if ! [[ -f $GOBIN/crypto ]]; then
    go install go.dedis.ch/dela/cli/crypto
  fi
  if ! [[ -f $GOBIN/dvoting ]]; then
    go install ./cli/dvoting
  fi

  echo "Installing node directories"
  for d in backend frontend; do
    DIR=web/$d
    if ! [[ -d $DIR/node_modules ]]; then
      (cd $DIR && npm ci)
    fi
  done
}

function keypair() {
  if ! [[ "$PUBLIC_KEY" ]]; then
    if ! [[ -f nodes/keypair ]]; then
      echo "Getting keypair"
      (cd web/backend && npm run keygen) | tail -n 2 >nodes/keypair
    fi
    . nodes/keypair
    export PUBLIC_KEY PRIVATE_KEY
  fi
}

function kill_nodes() {
  pkill dvoting || true

  echo "Waiting for nodes to stop"
  for n in $(seq 4); do
    NODEPORT=$((2000 + n * 2 - 2))
    while lsof -ln | grep -q :$NODEPORT; do sleep .1; done
  done
}

function init_nodes() {
  kill_nodes
  keypair

  echo "Starting nodes"
  for n in $(seq 4); do
    NODEPORT=$((2000 + n * 2 - 2))
    PROXYPORT=$((2001 + n * 2 - 2))
    NODEDIR=./nodes/node-$n
    mkdir -p $NODEDIR
    rm -f $NODEDIR/node.log
    dvoting --config $NODEDIR start --postinstall --proxyaddr :$PROXYPORT --proxykey $PUBLIC_KEY \
      --listen tcp://0.0.0.0:$NODEPORT --public grpc://localhost:$NODEPORT --routing tree --noTLS |
      ts "Node-$n: " | tee $NODEDIR/node.log &
  done

  echo "Waiting for nodes to start up"
  for n in $(seq 4); do
    NODEDIR=./nodes/node-$n
    while ! [[ -S $NODEDIR/daemon.sock && -f $NODEDIR/node.log && $(cat $NODEDIR/node.log | wc -l) -ge 2 ]]; do
      sleep .2
    done
  done
}

function init_dela() {
  echo "Initializing dela"
  echo "  Create a new chain with the nodes"
  for n in $(seq 4); do
    NODEDIR=./nodes/node-$n
    # add node to the chain
    MEMBERS="$MEMBERS --member $(dvoting --config $NODEDIR ordering export)"
  done
  dvoting --config ./nodes/node-1 ordering setup $MEMBERS

  echo "  Authorize the signer to handle the access contract on each node"
  for s in $(seq 4); do
    NODEDIR=./nodes/node-$s
    IDENTITY=$(crypto bls signer read --path $NODEDIR/private.key --format BASE64_PUBKEY)
    for n in $(seq 4); do
      NODEDIR=./nodes/node-$n
      dvoting --config $NODEDIR access add --identity "$IDENTITY"
    done
  done

  echo "  Update the access contract"
  for n in $(seq 4); do
    NODEDIR=./nodes/node-$n
    IDENTITY=$(crypto bls signer read --path $NODEDIR/private.key --format BASE64_PUBKEY)
    dvoting --config ./nodes/node-1 pool add --key ./nodes/node-1/private.key --args go.dedis.ch/dela.ContractArg \
      --args go.dedis.ch/dela.Access --args access:grant_id \
      --args 45564f54 --args access:grant_contract \
      --args go.dedis.ch/dela.Evoting --args access:grant_command --args all --args access:identity --args $IDENTITY \
      --args access:command --args GRANT
  done
}

function clean_dela(){
  rm -f cookies.txt
}

function kill_db() {
  docker rm -f postgres_dvoting || true
}

function clean_db(){
  rm -rf nodes/lmdb*
  rm -rf nodes/postgresql
}

function init_db() {
  kill_db

  echo "Starting postgres database"
  docker run -d -v "$(pwd)/web/backend/src/migration.sql:/docker-entrypoint-initdb.d/init.sql" \
    -e POSTGRES_PASSWORD=$DATABASE_PASSWORD -e POSTGRES_USER=$DATABASE_USERNAME \
    -v "$(pwd)/nodes/postgresql:/var/lib/postgresql/data" \
    --name postgres_dvoting -p 5432:5432 postgres:15 >/dev/null

  echo "Adding $REACT_APP_SCIPER_ADMIN to admin"
  (cd web/backend && npx ts-node src/cli.ts addAdmin --sciper $REACT_APP_SCIPER_ADMIN | grep -v Executing)
}

function kill_backend() {
  pkill -f "web/backend" || true
  rm -f cookies.txt
}

function start_backend() {
  kill_backend
  keypair

  echo "Running backend"
  (cd web/backend && npm run start-dev | ts "Backend: " &)

  while ! lsof -ln | grep -q :6000; do sleep .1; done
}

function kill_frontend() {
  pkill -f "web/frontend" || true
}

function start_frontend() {
  kill_frontend
  keypair

  echo "Running frontend"
  (cd web/frontend && npm run start | ts "Frontend: " &)
}

case "$1" in
clean)
  kill_frontend
  kill_nodes
  kill_backend
  kill_db
  clean_db
  clean_dela
  clean_build
  exit
  ;;

build)
  build_dela
  ;;

init_nodes)
  init_nodes
  ;;

init_dela)
  init_dela
  ;;

init_db)
  init_db
  ;;

backend)
  start_backend
  ;;

frontend)
  start_frontend
  ;;

kill)
  kill_frontend
  kill_nodes
  kill_backend
  kill_db
  ;;

simulate)
  if [[ ! -d epfl-nodes ]]; then
      echo "The simulated nodes need to be stored under the epfl-nodes directory."
      exit 1
  fi
  if ! grep -q "redirect go.dedis.ch/dela" go.mod; then
    echo "go.mod should redirect to a local version of dela with the run_epfl_dvoting_locally branch"
    exit 1
  fi
  rm -rf nodes
  cp -a epfl-nodes nodes
  build_dela
  init_nodes
  init_db
  start_backend
  start_frontend
  sleep 10
  ./scripts/local_proxies.sh
  ;;

*)
  build_dela
  init_nodes
  init_dela
  init_db
  start_backend
  start_frontend
  ;;
esac
