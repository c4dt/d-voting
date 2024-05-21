#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
. "$SCRIPT_DIR/local_login.sh"

echo "adding proxies"

for node in $(seq 0 3); do
  NodeAddr="/ip4/127.0.0.1/tcp/$((2000 + node * 2))/ws"
  ProxyAddr="http://localhost:$((2001 + node * 2))"
  echo -n "Adding proxy for node $((node + 1)): "
  curl -sk "$FRONTEND_URL/api/proxies/" -X POST -H 'Content-Type: application/json' -b cookies.txt \
    --data-raw "{\"NodeAddr\":\"$NodeAddr\",\"Proxy\":\"$ProxyAddr\"}"
  echo
done
