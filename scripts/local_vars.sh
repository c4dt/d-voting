export SCIPER_ADMIN=100100
export DATABASE_USERNAME=dvoting
export DATABASE_PASSWORD=postgres
export FRONTEND_URL="http://localhost:3000"
export DELA_PROXY_URL="http://localhost:2001"
export BACKEND_HOST="localhost"
export BACKEND_PORT="6000"
export SESSION_SECRET="session secret"
export REACT_APP_NOMOCK=on
# shellcheck disable=SC2155
export DB_PATH="$(pwd)/nodes/llmdb"
# The following two variables can be set to see log output from dela:
#export PROXY_LOG=info
#export LLVL=info
# Logging in without Gaspar and SCIPER 100100
export REACT_APP_DEV_LOGIN="true"
# uncomment this to enable TLS to test gaspar
#export HTTPS=true
# Create random voter-IDs to allow easier testing
export REACT_APP_RANDOMIZE_VOTE_ID="true"
