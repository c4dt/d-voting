#!/bin/bash -e

# The script must be called from the root of the github tree, else it returns an error.
# This script currently only works on Linux due to differences in network management on Windows/macOS.

if [[ $(git rev-parse --show-toplevel) != $(readlink -fn $(pwd)) ]]; then
  echo "ERROR: This script must be started from the root of the git repo";
  exit 1;
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
fi

source ./.env;
export COMPOSE_FILE=${COMPOSE_FILE:-./docker-compose/docker-compose.yml};


function setup() {
  docker compose build;
  docker compose up -d;
}

function teardown() {
  rm -f cookies.txt;
  docker compose down -v;
  docker image rm ghcr.io/c4dt/d-voting-frontend:latest ghcr.io/c4dt/d-voting-backend:latest ghcr.io/c4dt/d-voting-dela:latest;
}

function init_dela() {
  LEADER=dela-worker-0;
  echo "$LEADER is the initial leader node";

  echo "add nodes to the chain";
  MEMBERS=""
  for node in $(seq 0 3); do
    MEMBERS="$MEMBERS --member $(docker compose exec dela-worker-$node /bin/bash -c 'LLVL=error dvoting --config /data/node ordering export')";
  done
  docker compose exec "$LEADER" dvoting --config /data/node ordering setup $MEMBERS;

  echo "authorize signers to handle access contract on each node";
  for signer in $(seq 0 3); do
    IDENTITY=$(docker compose exec "dela-worker-$signer" crypto bls signer read --path /data/node/private.key --format BASE64_PUBKEY);
    for node in $(seq 0 3); do
      docker compose exec "dela-worker-$node" dvoting --config /data/node access add --identity "$IDENTITY";
    done
  done

  echo "update the access contract";
  for node in $(seq 0 3); do
    IDENTITY=$(docker compose exec dela-worker-"$node" crypto bls signer read --path /data/node/private.key --format BASE64_PUBKEY);
    docker compose exec "$LEADER" dvoting --config /data/node pool add\
        --key /data/node/private.key\
        --args go.dedis.ch/dela.ContractArg\
        --args go.dedis.ch/dela.Access\
        --args access:grant_id\
        --args 45564f54\
        --args access:grant_contract\
        --args go.dedis.ch/dela.Evoting \
        --args access:grant_command\
        --args all\
        --args access:identity\
        --args $IDENTITY\
        --args access:command\
        --args GRANT
  done
}

function local_login() {
  if ! [ -f cookies.txt ]; then
   echo "getting dummy login cookie";
   curl -k "$FRONT_END_URL/api/get_dev_login/$REACT_APP_SCIPER_ADMIN" -c cookies.txt -o /dev/null -s;
  fi
}

function is_dev_login() {
  [[ "$REACT_APP_DEV_LOGIN" == "true" ]]
}

function add_single_proxy() {
  echo "adding first proxy";
      curl -sk "$FRONT_END_URL/api/proxies/" -X POST -H 'Content-Type: application/json' -b cookies.txt --data "{\"NodeAddr\":\"grpc://dela-worker-0:$NODEPORT\",\"Proxy\":\"$DELA_PROXY_URL\"}";
}

# Adds the default admin to the dela blockchain. This is needed to add more proxies.
function add_admin() {
  echo "adding admin user $REACT_APP_SCIPER_ADMIN";
  curl -sk "$FRONT_END_URL/api/evoting/auth/addadmin" -X POST -H 'Content-Type: application/json'  -b cookies.txt --data "{\"TargetUserID\": \"$REACT_APP_SCIPER_ADMIN\"}";
}

# Adds the other proxies. Note that you need an admin account to do it.
# This is checked through the first proxy added in the "add_single_proxy" function.
function add_remaining_proxies() {
  for node in $(seq 1 3); do
    echo "adding proxy for node dela-worker-$node";
    curl -sk "$FRONT_END_URL/api/proxies/" -X POST -H 'Content-Type: application/json' -b cookies.txt --data "{\"NodeAddr\":\"grpc://dela-worker-$node:$NODEPORT\",\"Proxy\":\"$DELA_PROXY_SUBNET.$((254 - node)):$PROXYPORT\"}";
  done
}

case "$1" in

setup)
  setup;
  ;;

init_dela)
  init_dela;
  ;;

teardown)
  teardown;
  exit
  ;;

first_proxy)
  local_login
  add_single_proxy;
  ;;

add_admin)
  local_login
  add_admin;
  ;;

other_proxies)
  local_login
  add_remaining_proxies;
  ;;

*)
  setup;
  sleep 16;     # give DELA nodes time to start up
  init_dela;
  add_single_proxy;

  if is_dev_login; then
    local_login;
    add_admin;
    sleep 100;  # give DELA time to insert the token 
    add_remaining_proxies;
  else
    echo "";
    echo "Open $FRONT_END_URL and log in with Microsoft Entra ID.";
    echo "The remaining proxies can then be added from the admin page.";
  fi
  ;;
esac
