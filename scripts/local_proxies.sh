#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
. "$SCRIPT_DIR/local_login.sh"

echo "adding proxies"

for node in $(seq 1 4); do
  NodeAddr=$(dvoting --config "./nodes/node-$node" list address |
    awk '/^\/.*\/p2p\// { address=$0 } END { sub(/\r$/, "", address); print address }')
  if [[ -z "$NodeAddr" ]]; then
    echo "ERROR: could not read the MinoWS address for node $node" >&2
    exit 1
  fi

  ProxyAddr="http://localhost:$((1999 + node * 2))"
  echo -n "Adding proxy for node $node: "
  curl -sk "$FRONTEND_URL/api/proxies/" -X POST -H 'Content-Type: application/json' -b cookies.txt \
    --data-raw "{\"NodeAddr\":\"$NodeAddr\",\"Proxy\":\"$ProxyAddr\"}"
  echo
done
