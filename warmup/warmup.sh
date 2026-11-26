#!/usr/bin/env bash
# warmup.sh - warm-up of JP55MULE validateSalesOrder (session pool) through the Atina REST API.
#
# Sends a warm-up request (correlationId WARMUP-..., no detail): no order is created and nothing is written in JDE.
# The service runs GetCurrentUTime on the Atina session and, with
# JP55MULE_ORDER_VALIDATION_WORKER_CONNECTION=POOLED, creates and fills the session pool before answering
# (at most JP55MULE_ORDER_VALIDATION_WARMUP_TIMEOUT_SECONDS). With the pool already full it answers at once, so it can
# run periodically (cron): it also repairs the pool after a restart of the microservice or of the JDE server.
#
# Environment (credentials never in this file):
#   WARMUP_ATINA_URL      URL of the Atina REST gateway (8086), not the gRPC port of the microservice (8077)
#                                                                   (default http://localhost:8086)
#   WARMUP_JDE_USER       JDE user of the pool (the one MuleSoft uses)          (required)
#   WARMUP_JDE_PASSWORD   its password                                          (required)
#   WARMUP_JDE_ENVIRONMENT                                          (default JUAT920)
#   WARMUP_JDE_ROLE                                                 (default *ALL)
#   WARMUP_WAIT_SECONDS   how long to retry the login while the microservice starts (default 300)
#   WARMUP_CALL_TIMEOUT_SECONDS  HTTP timeout of the warm-up call   (default 300; above the service wait of 120 s)
#   WARMUP_LOCK_FILE      lock against overlapping runs             (default /tmp/jp55mule-warmup.lock)
#
# Exit codes: 0 OK, 1 configuration, 2 login failed, 3 warm-up call failed, 0 also when another run holds the lock.
# Output: one line per run with the ORDER_VALIDATION_WARMUP summary of the service.

set -u

ATINA_URL=${WARMUP_ATINA_URL:-http://localhost:8086}
JDE_USER=${WARMUP_JDE_USER:-}
JDE_PASSWORD=${WARMUP_JDE_PASSWORD:-}
JDE_ENVIRONMENT=${WARMUP_JDE_ENVIRONMENT:-JUAT920}
JDE_ROLE=${WARMUP_JDE_ROLE:-*ALL}
WAIT_SECONDS=${WARMUP_WAIT_SECONDS:-300}
CALL_TIMEOUT=${WARMUP_CALL_TIMEOUT_SECONDS:-300}
LOCK_FILE=${WARMUP_LOCK_FILE:-/tmp/jp55mule-warmup.lock}
OPERATION=epastry.e1.bssv.JP55MULE.SalesOrderValidationManager.validateSalesOrder

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') jp55mule-warmup $*"
}

if [ -z "$JDE_USER" ] || [ -z "$JDE_PASSWORD" ]; then
    log "ERROR WARMUP_JDE_USER and WARMUP_JDE_PASSWORD are required"
    exit 1
fi
# Values go into JSON without a JSON tool: refuse characters that would need escaping.
for value in "$JDE_USER" "$JDE_PASSWORD" "$JDE_ENVIRONMENT" "$JDE_ROLE"; do
    case "$value" in
        *\"*|*\\*) log "ERROR credentials or environment contain a quote or a backslash"; exit 1 ;;
    esac
done

# One run at a time (Linux flock; skipped when flock is not installed).
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "SKIPPED another warm-up is running"
        exit 0
    fi
fi

umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jp55mule-warmup.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# Login: password through stdin (not in the process list), token only in a private temporary file.
login() {
    printf '{"user":"%s","password":"%s","environment":"%s","role":"%s","wsconnection":true,"transactionID":"2"}' \
        "$JDE_USER" "$JDE_PASSWORD" "$JDE_ENVIRONMENT" "$JDE_ROLE" \
        | curl -s -m 120 -o "$WORK/login.json" -w '%{http_code}' -X POST "$ATINA_URL/v1/session/login" \
            -H 'Accept: application/json' -H 'Content-Type: application/json' -H 'TransactionId: 2' \
            -H "correlationUUID: jp55mule-warmup-login-$(date +%s)" --data-binary @-
}

deadline=$(( $(date +%s) + WAIT_SECONDS ))
token=""
while :; do
    http=$(login)
    if [ "$http" = "200" ]; then
        token=$(sed -n 's/.*"jwtToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORK/login.json")
        [ -n "$token" ] && break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        log "ERROR login failed (http=$http) after ${WAIT_SECONDS}s at $ATINA_URL"
        exit 2
    fi
    sleep 10
done
printf 'Authorization: Bearer %s\n' "$token" > "$WORK/auth.header"
token=""

correlation="WARMUP-$(hostname 2>/dev/null || echo host)-$(date +%Y%m%d%H%M%S)"
printf '{"operacionKey":"%s","connectorName":"WS","wsconnection":true,"transactionID":"0","listaDeValores":{"correlationId":"%s"}}' \
    "$OPERATION" "$correlation" > "$WORK/body.json"

start=$(date +%s)
http=$(curl -s -m "$CALL_TIMEOUT" -o "$WORK/response.json" -w '%{http_code}' -X POST "$ATINA_URL/v1/operations/execute" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' -H @"$WORK/auth.header" \
    -H 'TransactionId: 0' -H "correlationUUID: $correlation" --data-binary @"$WORK/body.json")
elapsed=$(( $(date +%s) - start ))

if [ "$http" != "200" ]; then
    log "ERROR warm-up call failed http=$http seconds=$elapsed response=$(head -c 500 "$WORK/response.json" | tr '\n' ' ')"
    exit 3
fi
summary=$(grep -o 'WARMUP correlationId=[^"]*' "$WORK/response.json" | head -1)
if [ -z "$summary" ]; then
    summary="(no summary in the response: see ORDER_VALIDATION_WARMUP $correlation in the microservice log)"
fi
log "OK http=$http seconds=$elapsed $summary"
exit 0
