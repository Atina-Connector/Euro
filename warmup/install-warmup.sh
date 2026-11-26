#!/usr/bin/env bash
# install-warmup.sh - installs the JP55MULE warm-up on the host of the Atina microservice (Linux, as root).
#
#   sudo bash install-warmup.sh               install (or update) and run one warm-up as a test
#   sudo bash install-warmup.sh --test        only run one warm-up with the installed files
#   sudo bash install-warmup.sh --uninstall   remove everything it installed
#
# Installs (from the folder of this script):
#   /opt/jp55mule/warmup.sh                  the warm-up script
#   /etc/jp55mule-warmup.env                 URL and credentials (mode 600; asked only the first time)
#   /etc/cron.d/jp55mule-warmup              every 10 minutes
#   /etc/logrotate.d/jp55mule-warmup         weekly rotation of /var/log/jp55mule-warmup.log

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
OPT_DIR=/opt/jp55mule
ENV_FILE=/etc/jp55mule-warmup.env
CRON_FILE=/etc/cron.d/jp55mule-warmup
LOGROTATE_FILE=/etc/logrotate.d/jp55mule-warmup
LOG_FILE=/var/log/jp55mule-warmup.log

say() { echo "[install-warmup] $*"; }
fail() { echo "[install-warmup] ERROR $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "run it as root: sudo bash $0"
[ "$(uname -s)" = "Linux" ] || fail "this installer is for Linux (/etc/cron.d); on another system install the cron by hand"

run_test() {
    [ -x "$OPT_DIR/warmup.sh" ] && [ -f "$ENV_FILE" ] || fail "not installed yet"
    say "test run (can take up to a few minutes the first time after a restart)..."
    set +e
    ( . "$ENV_FILE" && "$OPT_DIR/warmup.sh" ) 2>&1 | tee -a "$LOG_FILE"
    local code=${PIPESTATUS[0]}
    set -e
    if [ "$code" = "0" ]; then
        say "test OK (also written to $LOG_FILE)"
    else
        say "test FAILED with exit code $code (1 configuration, 2 login, 3 warm-up call): check $ENV_FILE"
    fi
    return 0
}

case "${1:-}" in
    --uninstall)
        rm -f "$CRON_FILE" "$LOGROTATE_FILE" "$OPT_DIR/warmup.sh" "$ENV_FILE"
        rmdir "$OPT_DIR" 2>/dev/null || true
        say "removed $CRON_FILE, $LOGROTATE_FILE, $OPT_DIR/warmup.sh and $ENV_FILE ($LOG_FILE kept)"
        exit 0
        ;;
    --test)
        run_test
        exit 0
        ;;
    "") ;;
    *) fail "unknown option $1 (use --test or --uninstall)" ;;
esac

# --- requirements ---------------------------------------------------------------------------------------------
for f in warmup.sh jp55mule-warmup.cron jp55mule-warmup.logrotate; do
    [ -f "$DIR/$f" ] || fail "$DIR/$f not found: copy the whole warmup folder"
done
command -v curl >/dev/null 2>&1 || fail "curl is not installed"
curl_version=$(curl --version | head -1 | awk '{print $2}')
curl_major=${curl_version%%.*}
curl_minor=$(echo "$curl_version" | cut -d. -f2)
if [ "$curl_major" -lt 7 ] || { [ "$curl_major" -eq 7 ] && [ "$curl_minor" -lt 55 ]; }; then
    fail "curl $curl_version is too old (7.55 or newer is needed)"
fi
command -v flock >/dev/null 2>&1 || say "WARNING flock is not installed (util-linux): runs are not protected against overlapping"
[ -d /etc/cron.d ] || fail "/etc/cron.d does not exist: is cron installed? (Debian/Ubuntu: cron, RHEL: cronie)"
if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet cron 2>/dev/null && ! systemctl is-active --quiet crond 2>/dev/null; then
        say "WARNING the cron service does not look active (systemctl status cron / crond)"
    fi
fi

# --- files ----------------------------------------------------------------------------------------------------
install -d -m 755 "$OPT_DIR"
install -m 755 "$DIR/warmup.sh" "$OPT_DIR/warmup.sh"
say "installed $OPT_DIR/warmup.sh"

if [ -f "$ENV_FILE" ]; then
    say "kept the existing $ENV_FILE (to change the credentials: edit it, or --uninstall and install again)"
else
    say "configuration of $ENV_FILE (Enter keeps the value in brackets)"
    read -r -p "  Atina REST URL [http://localhost:8086]: " url
    read -r -p "  JDE user (the one MuleSoft uses) [ATINAD]: " user
    read -r -p "  JDE environment [JUAT920]: " environment
    read -r -p "  JDE role [*ALL]: " role
    read -r -s -p "  JDE password: " password
    echo
    url=${url:-http://localhost:8086}; user=${user:-ATINAD}; environment=${environment:-JUAT920}; role=${role:-*ALL}
    [ -n "$password" ] || fail "the password is required"
    for value in "$url" "$user" "$environment" "$role" "$password"; do
        case "$value" in
            *\'*|*\"*|*\\*) fail "values cannot contain quotes or backslashes" ;;
        esac
    done
    umask 077
    {
        echo "# JP55MULE warm-up (read by /etc/cron.d/jp55mule-warmup). Mode 600: it holds a password."
        echo "export WARMUP_ATINA_URL='$url'"
        echo "export WARMUP_JDE_USER='$user'"
        echo "export WARMUP_JDE_PASSWORD='$password'"
        echo "export WARMUP_JDE_ENVIRONMENT='$environment'"
        echo "export WARMUP_JDE_ROLE='$role'"
    } > "$ENV_FILE"
    password=""
    chmod 600 "$ENV_FILE"
    chown root:root "$ENV_FILE"
    say "created $ENV_FILE (mode 600)"
fi

install -m 644 "$DIR/jp55mule-warmup.cron" "$CRON_FILE"
install -m 644 "$DIR/jp55mule-warmup.logrotate" "$LOGROTATE_FILE"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"
say "installed $CRON_FILE (every 10 minutes) and $LOGROTATE_FILE"

run_test
say "done. Follow the runs with: tail -f $LOG_FILE"
