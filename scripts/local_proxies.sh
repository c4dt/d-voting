#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
. "$SCRIPT_DIR/local_login.sh"

echo "adding proxies"

CLI_BIN=./bin/dvoting-libp2p
echo "CLI_BIN: $CLI_BIN"

for node in $(seq 0 3); do
  NODEDIR=./nodes/node-$((node+1))
  NodeAddr=$(LLVL=warn $CLI_BIN --config $NODEDIR list address)
  echo "NodeAddr: $NodeAddr"
  ProxyAddr="http://localhost:$((2001 + node * 2))"
  echo "ProxyAddr: $ProxyAddr"
  echo -n "Adding proxy for node $((node + 1)): "
  curl -sk "$FRONTEND_URL/api/proxies/" -X POST -H 'Content-Type: application/json' -b cookies.txt \
    --data-raw "{\"NodeAddr\":\"$NodeAddr\",\"Proxy\":\"$ProxyAddr\"}"
  echo
done
