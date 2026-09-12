#!/usr/bin/env bash
set -e

# Default port if Railway doesn't set one
PORT="${PORT:-8080}"
export PORT

# Require AUTH_TOKEN to be set
if [ -z "$AUTH_TOKEN" ]; then
  echo "ERROR: AUTH_TOKEN environment variable must be set"
  exit 1
fi

# Render nginx config with env vars
envsubst '${PORT} ${AUTH_TOKEN}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Concurrency / parallelism knobs are parameterised so we can re-tune
# the throughput-vs-memory point from the Railway dashboard without a
# redeploy. See the loki-config.yaml inline comments for the chosen
# defaults and the math behind them.
# Memory budget (container is 64 GB / 32 vCPU):
#   16 workers x <=2.2 GB (1 GB split cap x ~2.2 heap per processed byte,
#   measured 2026-09-12) = 35 GB, + 2 GB results cache + ~2 GB baseline
#   = 39 GB < GOMEMLIMIT 44 GiB < 59.6 GiB cgroup limit.
#   Load test with three concurrent 6h three-service queries: RSS 39.6 GiB.
LOKI_QUERIER_MAX_CONCURRENT="${LOKI_QUERIER_MAX_CONCURRENT:-16}"
LOKI_MAX_QUERY_PARALLELISM="${LOKI_MAX_QUERY_PARALLELISM:-16}"
LOKI_TSDB_MAX_QUERY_PARALLELISM="${LOKI_TSDB_MAX_QUERY_PARALLELISM:-64}"
LOKI_QUERY_TIMEOUT="${LOKI_QUERY_TIMEOUT:-3m}"
LOKI_MAX_QUERY_BYTES_READ="${LOKI_MAX_QUERY_BYTES_READ:-50GB}"
LOKI_MAX_QUERIER_BYTES_READ="${LOKI_MAX_QUERIER_BYTES_READ:-1GB}"
GOMEMLIMIT="${GOMEMLIMIT:-44GiB}"
export LOKI_QUERIER_MAX_CONCURRENT LOKI_MAX_QUERY_PARALLELISM LOKI_TSDB_MAX_QUERY_PARALLELISM LOKI_QUERY_TIMEOUT LOKI_MAX_QUERY_BYTES_READ LOKI_MAX_QUERIER_BYTES_READ GOMEMLIMIT
echo "GOMEMLIMIT                      = $GOMEMLIMIT"
echo "querier.max_concurrent          = $LOKI_QUERIER_MAX_CONCURRENT"
echo "max_query_parallelism           = $LOKI_MAX_QUERY_PARALLELISM"
echo "tsdb_max_query_parallelism      = $LOKI_TSDB_MAX_QUERY_PARALLELISM"
echo "query_timeout                   = $LOKI_QUERY_TIMEOUT"
echo "max_query_bytes_read            = $LOKI_MAX_QUERY_BYTES_READ"
echo "max_querier_bytes_read          = $LOKI_MAX_QUERIER_BYTES_READ"

# Strip the protocol scheme from S3_ENDPOINT. Railway populates the bucket
# variable as a full URL (e.g. `https://t3.storageapi.dev`) but Loki's S3
# client wants a hostname only — HTTPS is controlled separately by
# `insecure: false` in loki-config.yaml. Doing it here lets the Railway
# env var stay as a clean `${{"Loki Bucket".ENDPOINT}}` reference.
if [ -n "$S3_ENDPOINT" ]; then
  S3_ENDPOINT="${S3_ENDPOINT#https://}"
  S3_ENDPOINT="${S3_ENDPOINT#http://}"
  export S3_ENDPOINT
fi

# Start Loki in the background.
# `-config.expand-env=true` lets the YAML reference Railway env vars via
# `${VAR}` syntax (used for the S3 credentials/endpoint/bucket).
/usr/bin/loki -config.file=/etc/loki/loki-config.yaml -config.expand-env=true &
LOKI_PID=$!

# Wait for Loki to be ready
echo "Waiting for Loki to start (pid=$LOKI_PID)..."
for i in $(seq 1 60); do
  if ! kill -0 "$LOKI_PID" 2>/dev/null; then
    echo "ERROR: Loki exited before becoming ready"
    exit 1
  fi
  if wget -q -O /dev/null http://127.0.0.1:3100/ready 2>/dev/null; then
    echo "Loki is ready"
    break
  fi
  sleep 1
done

# Start nginx in the background instead of exec'ing it, so we can supervise
# alongside Loki. Previously nginx ran as foreground PID 1 and Loki ran as a
# background child; when Loki was OOM-killed (signal 9 from the kernel)
# nginx kept running, Railway considered the container healthy, and every
# /loki/* call returned 502 indefinitely until someone manually redeployed.
# Now whichever process exits first takes the whole container down (exit 1)
# and Railway's ON_FAILURE restart policy in railway.toml brings it back.
echo "Starting nginx on port $PORT"
nginx -g 'daemon off;' &
NGINX_PID=$!

# Forward termination signals so a clean Railway stop kills both children
# and exits 0 (no spurious restart loop on intentional shutdowns).
trap 'echo "received termination signal"; kill -TERM "$LOKI_PID" "$NGINX_PID" 2>/dev/null || true; wait; exit 0' TERM INT

# Block until either child exits. `wait -n` requires bash (Alpine's /bin/sh
# is BusyBox ash, hence the bash shebang and `apk add bash` in Dockerfile);
# it's event-driven, so we react in milliseconds rather than the seconds a
# polling loop would cost.
set +e
wait -n "$LOKI_PID" "$NGINX_PID"
EXIT_CODE=$?
set -e

if ! kill -0 "$LOKI_PID" 2>/dev/null; then
  echo "ERROR: Loki (pid=$LOKI_PID) exited with code $EXIT_CODE; killing nginx and exiting so Railway restarts the container"
else
  echo "ERROR: nginx (pid=$NGINX_PID) exited with code $EXIT_CODE; killing Loki and exiting so Railway restarts the container"
fi

kill -TERM "$LOKI_PID" "$NGINX_PID" 2>/dev/null || true
sleep 1
kill -KILL "$LOKI_PID" "$NGINX_PID" 2>/dev/null || true

exit 1
