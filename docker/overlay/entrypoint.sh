#!/usr/bin/env bash
###
# File: entrypoint.sh
# Project: overlay
# File Created: Friday, 18th October 2024 5:05:51 pm
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 18th August 2025 12:17:10 pm
# Modified By: Josh.5 (jsunnex@gmail.com)
###
set -eu

################################################
# --- Export config
#
export docker_version
docker_version=$(docker --version | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
if [ -n "${DOCKER_VERSION:-}" ]; then
    docker_version=${DOCKER_VERSION:?}
fi
export dind_continer_name="sentry-swarm-dind"
export dind_bridge_network_name="sentry-swarm-dind-net"
export dind_cache_path="${SENTRY_DATA_PATH:?}/docker-cache"
export dind_run_path="${SENTRY_DATA_PATH:?}/docker-sock"
export fluentd_image_tag="v1.19-debian-1"
export fluentd_continer_name="sentry-swarm-fluentd"
export fluentd_data_path="${SENTRY_DATA_PATH}/fluentd"
export custom_docker_network_name="sentry-private-net"
export cmd_prefix="docker exec --workdir=${SENTRY_DATA_PATH:?}/self_hosted ${dind_continer_name:?}"
export docker_cmd="${cmd_prefix:?} docker"
export docker_compose_cmd="${cmd_prefix:?} docker compose"
export install_cmd="${cmd_prefix:?} ./install.sh --skip-user-creation --no-report-self-hosted-issues"

supervisor_pid=""

################################################
# --- Create TERM monitor
#
_term() {
    echo
    echo -e "\e[35m[ Stopping manager service ]\e[0m"
    if [ -n "${supervisor_pid:-}" ] && kill -0 "$supervisor_pid" 2>/dev/null; then
        kill -TERM "$supervisor_pid" 2>/dev/null || true
    fi

    if [ "${KEEP_ALIVE:-true}" = "false" ]; then
        echo "  - The 'KEEP_ALIVE' env variable is set to false. Running all shutdown scripts"
        for stop_script in /init.d/stop/*.sh; do
            if [ -f "${stop_script:?}" ]; then
                echo
                echo -e "\e[33m[ ${stop_script:?}: executing... ]\e[0m"
                sed -i 's/\r$//' "${stop_script:?}"
                source "${stop_script:?}"
            fi
        done
        echo
    else
        echo "  - The 'KEEP_ALIVE' env variable is set to ${KEEP_ALIVE:-true}. Stopping manager only."
    fi
    exit 0
}
trap _term SIGTERM SIGINT

################################################
# --- Logging helper functions
#
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
DATE_CMD="${DATE_CMD:-$(command -v gdate || command -v date)}"

__LOG_TS_FMT="+%Y-%m-%d %H:%M:%S.%N"
ns="$("$DATE_CMD" +%N 2>/dev/null || echo N)"
case "$ns" in
*N* | N) __LOG_TS_FMT="+%Y-%m-%d %H:%M:%S" ;;
esac

__ts() { "$DATE_CMD" "$__LOG_TS_FMT"; }

__log_line() {
    printf '[%s] [%s]: %s\n' "$SCRIPT_NAME" "$(__ts)" "$*"
}

log_header() { __log_line "🚀 $*"; }
log_error() { __log_line "❌ $*"; }

################################################
# --- Enforce minimum supported Sentry version
#
min_sentry_version="25.5.1"
if [ "$(printf '%s\n' "${SENTRY_VERSION:?}" "$min_sentry_version" | sort -V | head -n1)" != "$min_sentry_version" ]; then
    log_error "Minimum supported SENTRY_VERSION is ${min_sentry_version}, but found ${SENTRY_VERSION}"
    exit 1
fi

################################################
# --- Run through startup init scripts
#
echo
echo -e "\e[35m[ Running startup scripts ]\e[0m"
for start_script in /init.d/start/*.sh; do
    if [ -f "${start_script:?}" ]; then
        echo
        echo -e "\e[34m[ ${start_script:?}: executing... ]\e[0m"
        sed -i 's/\r$//' "${start_script:?}"
        source "${start_script:?}"
    fi
done

# The sourced startup scripts calculate these values. Export only the runtime
# recovery inputs required by the Python supervisor.
export DIND_CONTAINER_NAME="${dind_continer_name:?}"
export DIND_RUN_CMD="${DIND_RUN_CMD:?}"
export DIND_NET_CONN_CMD="${DIND_NET_CONN_CMD:?}"
export CPU_PERIOD="${CPU_PERIOD:?}"
export SERVICES_CPU_QUOTA="${SERVICES_CPU_QUOTA:?}"

sleep 10 &
wait $! || true

log_header "Starting persistent Python supervisor"
python3 /defaults/supervisor/supervisor.py &
supervisor_pid=$!

supervisor_status=0
wait "$supervisor_pid" || supervisor_status=$?
supervisor_pid=""
if [ "$supervisor_status" -ne 0 ]; then
    log_error "Python supervisor exited with status ${supervisor_status}"
fi
exit "$supervisor_status"
