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
export docker_version=$(docker --version | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
if [ "X${DOCKER_VERSION:-}" != "X" ]; then
    export docker_version=${DOCKER_VERSION:?}
fi
export dind_continer_name="sentry-swarm-dind"
export dind_bridge_network_name="sentry-swarm-dind-net"
export dind_cache_path="${SENTRY_DATA_PATH:?}/docker-cache"
export dind_run_path="${SENTRY_DATA_PATH:?}/docker-sock"
export fluentd_image_tag="v1.17-debian-1"
export fluentd_continer_name="sentry-swarm-fluentd"
export fluentd_data_path="${SENTRY_DATA_PATH}/fluentd"
export custom_docker_network_name="sentry-private-net"
export cmd_prefix="docker exec --workdir=${SENTRY_DATA_PATH:?}/self_hosted ${dind_continer_name:?}"
export docker_cmd="${cmd_prefix:?} docker"
export docker_compose_cmd="${cmd_prefix:?} docker compose"
export install_cmd="${cmd_prefix:?} ./install.sh --skip-user-creation --no-report-self-hosted-issues"

################################################
# --- Create TERM monitor
#
_term() {
    echo
    echo -e "\e[35m[ Stopping manager service ]\e[0m"
    if [ "${KEEP_ALIVE}" = "false" ]; then
        echo "  - The 'KEEP_ALIVE' env variable is set to ${KEEP_ALIVE:?}. Running all shutdown scripts"
        # Run all stop scripts
        for stop_script in /init.d/stop/*.sh; do
            if [ -f ${stop_script:?} ]; then
                echo
                echo -e "\e[33m[ ${stop_script:?}: executing... ]\e[0m"
                sed -i 's/\r$//' "${stop_script:?}"
                source "${stop_script:?}"
            fi
        done
        echo
    else
        echo "  - The 'KEEP_ALIVE' env variable is set to ${KEEP_ALIVE:?}. Stopping manager only."
    fi
    exit 0
}
trap _term SIGTERM SIGINT

################################################
# --- Logging helper functions
#
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
DATE_CMD="${DATE_CMD:-$(command -v gdate || command -v date)}"

# Choose timestamp format (fallback if %N unsupported)
__LOG_TS_FMT="+%Y-%m-%d %H:%M:%S.%N"
ns="$("$DATE_CMD" +%N 2>/dev/null || echo N)"
case "$ns" in
*N* | N) __LOG_TS_FMT="+%Y-%m-%d %H:%M:%S" ;;
esac

__ts() { "$DATE_CMD" "$__LOG_TS_FMT"; }

__log_line() {
    printf '[%s] [%s]: %s %s\n' "$SCRIPT_NAME" "$(__ts)" "$*"
}

log_header() { __log_line "🚀 $@"; }
log_subheader() { __log_line "➡️ $@"; }
log_task() { __log_line "⏳ $@"; }
log_step() { __log_line "🔹 $@"; }
log_info() { __log_line "ℹ️ $@"; }
log_warn() { __log_line "⚠️ $@"; }
log_error() { __log_line "❌ $@"; }
log_success() { __log_line "✅ $@"; }

################################################
# --- Enforce minimum supported Sentry version
#
min_sentry_version="25.5.1"
if [ "$(printf '%s\n' "${SENTRY_VERSION:?}" "${min_sentry_version}" | sort -V | head -n1)" != "${min_sentry_version}" ]; then
    log_error "Minimum supported SENTRY_VERSION is ${min_sentry_version}, but found ${SENTRY_VERSION}"
    exit 1
fi

################################################
# --- Run through startup init scripts
#
echo
echo -e "\e[35m[ Running startup scripts ]\e[0m"
for start_script in /init.d/start/*.sh; do
    if [ -f ${start_script:?} ]; then
        echo
        echo -e "\e[34m[ ${start_script:?}: executing... ]\e[0m"
        sed -i 's/\r$//' "${start_script:?}"
        source "${start_script:?}"
    fi
done

################################################
# --- Create compose stack monitors
#
# $> docker_compose_cmd="${cmd_prefix:?} docker compose -f ./docker-compose.yml -f ./docker-compose.custom.yml"
_log_monitor() {
    local emoji_prefix="🔎📄"
    log_header "Starting log monitor (${emoji_prefix})"
    sleep 10 &
    wait $! || true

    local interval=60
    local log_monitor_config_file="/defaults/log-monitor/config.json"
    local log_monitor_since="3m"

    while true; do
        log_subheader "(${emoji_prefix}) Checking logs (since ${log_monitor_since}) against configured patterns"

        # Gather all compose services once per loop
        local -a all_services=()
        mapfile -t all_services < <(${docker_compose_cmd:?} config --services)

        local errors_found="false"
        local service_count
        service_count=$(yq e 'length' "${log_monitor_config_file:?}")

        # Aggregate description for a single webhook
        local errors_description="" matches=0

        for i in $(seq 0 $((service_count - 1))); do
            # Read regex and patterns from config (raw strings)
            local svc_regex
            svc_regex=$(yq e -r ".[$i].service" "$log_monitor_config_file")
            local patterns
            patterns=$(yq e -r ".[$i].patterns[]" "$log_monitor_config_file" 2>/dev/null || true)

            # Skip if no patterns
            [ -z "$patterns" ] && continue

            # Build candidate services matching the regex
            local -a candidates=()
            local svc
            for svc in "${all_services[@]}"; do
                if [[ "$svc" =~ $svc_regex ]]; then
                    candidates+=("$svc")
                fi
            done

            # No matches for this rule
            [ ${#candidates[@]} -eq 0 ] && continue

            # Iterate each matching service and its containers
            local cand
            for cand in "${candidates[@]}"; do
                log_step "(${emoji_prefix}) Checking service '$cand' against error pattern set #$((i + 1))"
                local container_ids
                container_ids=$(${docker_compose_cmd:?} ps -q "$cand" || true)
                [ -z "$container_ids" ] && continue

                local cid
                for cid in $container_ids; do
                    # Read logs in this shell so we can set errors_found
                    local log_line_count=0
                    while IFS= read -r log_line; do
                        log_line_count=$((log_line_count + 1))
                        # Check each configured pattern (ERE) against the log line
                        while IFS= read -r pattern; do
                            [ -z "$pattern" ] && continue
                            if printf '%s\n' "$log_line" | grep -qE -- "$pattern"; then
                                errors_found="true"
                                matches=$((matches + 1))
                                log_error "(${emoji_prefix}) ${cand}: matched pattern '${pattern}' on line #${log_line_count}"

                                # Append a line to the aggregated description
                                local cid_short="${cid:0:12}"
                                errors_description+="• ${cand} (${cid_short}) — matched pattern: ${pattern}\\n"

                            fi
                        done <<<"$patterns"
                    done < <(${docker_cmd:?} logs --since "$log_monitor_since" "$cid" 2>&1)
                done
            done
        done

        if [ "$errors_found" = "true" ]; then
            log_warn "(${emoji_prefix}) ${matches} error(s) found. Sending aggregated webhook and re-checking in ${interval}s..."
            # Trim trailing newline for a tidier embed
            local desc_trimmed="${errors_description%\\n}"

            if [ -n "${NOTIFY_DISCORD_FOR_ERRORS_IN_LOGS:-}" ]; then
                # Build from Discord webhook template
                local discord_payload=$(
                    DISCORD_CONTENT="🚨 Sentry log monitor found ${matches} error(s)" \
                        DISCORD_TITLE="Log Errors Detected" \
                        DISCORD_DESCRIPTION="${desc_trimmed}" \
                        DISCORD_FOOTER="Generated at $(date)" \
                        envsubst </defaults/log-monitor/notifications-body-discord.tmpl.json
                )
                wget --header="Content-Type: application/json" \
                    --post-data "${discord_payload:?}" \
                    --timeout=10 --tries=1 \
                    -qO /dev/null "${NOTIFY_DISCORD_FOR_ERRORS_IN_LOGS}" ||
                    log_error "(${emoji_prefix}) Failed to send Discord webhook"
            fi
            if [ "${EXIT_ON_ERRORS_IN_LOGS:-}" = "true" ]; then
                log_info "(${emoji_prefix}) Flagging monitor to exit"
                : >/tmp/sentry-log-monitor.error
            fi
        else
            log_success "(${emoji_prefix}) No errors found. Sleeping ${interval}s..."
        fi
        sleep "${interval}" &
        wait $! || true
    done
}

_stack_monitor() {
    local emoji_prefix="👀🌡️"
    log_header "Starting stack monitor (${emoji_prefix:?})"

    cd "${SENTRY_DATA_PATH:?}/self_hosted"

    local interval=60
    local grace=60
    local ignored_services="geoipupdate|place_holder"

    while true; do
        log_subheader "(${emoji_prefix:?}) Running health checks for all services at $(date)"

        # 1) Containers exited with non-zero (global)
        mapfile -t exited_nonzero < <(
            ${docker_compose_cmd:?} ps --all --format "table {{.Service}}\t{{.RunningFor}}\t{{.Status}}" --filter "status=exited" |
                grep -v "^SERVICE" |
                grep -v "Exit 0" |
                grep -vE "${ignored_services:?}" || true
        )

        # 2) Build service list
        local services
        if [ "${WEB_ONLY_MAINTENANCE_MODE:-}" = "true" ]; then
            services="web nginx"
        else
            services="$(${docker_compose_cmd:?} config --services | grep -Ev "${ignored_services:?}")"
        fi

        # 3) Check services in parallel; track ONLY our PIDs
        local tmpdir
        tmpdir="$(mktemp -d)"
        local -a pids=()
        for service in $services; do
            (
                # Get status line(s) for this service
                local lines
                lines="$(${docker_compose_cmd:?} ps --format "table {{.Service}} {{.Status}}" 2>/dev/null | awk -v s="${service}" '$1==s')"
                # Treat as OK if any replica shows Up; otherwise FAIL
                if echo "${lines}" | grep -q "Up"; then
                    printf "OK|%s\n" "${service}" >"${tmpdir}/${service}.result"
                else
                    if [ -n "${lines}" ]; then
                        # Persist first line (or all lines if you prefer)
                        printf "FAIL|%s|%s\n" "${service}" "$(echo "${lines}" | head -n1)" >"${tmpdir}/${service}.result"
                    else
                        printf "FAIL|%s|%s\n" "${service}" "No running container(s) found" >"${tmpdir}/${service}.result"
                    fi
                fi
            ) &
            pids+=($!)
        done
        # Wait ONLY for our spawned checks (cannot do blanket wait as the log monitor is running at this point also)
        for pid in "${pids[@]}"; do
            wait "${pid}" || true
        done

        # 4) Collate results
        local -a failed_services=()
        local -a failed_status_lines=()
        local f row kind svc rest
        for f in "${tmpdir}"/*.result; do
            [ -e "$f" ] || continue
            row="$(cat "$f")"
            kind="${row%%|*}"
            rest="${row#*|}"
            case "${kind}" in
            OK) : ;;
            FAIL)
                svc="${rest%%|*}"
                failed_services+=("${svc}")
                failed_status_lines+=("${rest#*|}")
                ;;
            esac
        done
        rm -rf "${tmpdir}"

        # 5) Consider log-monitor flag
        local log_flag=false
        if [ -f /tmp/sentry-log-monitor.error ]; then
            log_flag=true
        fi

        # 6) Check results & exit if errors are found
        if ((${#exited_nonzero[@]} > 0 || ${#failed_services[@]} > 0)) || [ "${log_flag}" = "true" ]; then
            log_error "(${emoji_prefix:?}) Failures detected"

            if ((${#exited_nonzero[@]} > 0)); then
                log_info "(${emoji_prefix:?}) Containers exited with non-zero:"
                printf '      • %s\n' "${exited_nonzero[@]}"
            fi

            if ((${#failed_services[@]} > 0)); then
                log_info "(${emoji_prefix:?}) Services not running:"
                for i in "${!failed_services[@]}"; do
                    printf '      • %s — %s\n' "${failed_services[$i]}" "${failed_status_lines[$i]}"
                done
            fi

            if [ "${log_flag}" = "true" ]; then
                log_info "(${emoji_prefix:?}) Log monitor flagged an error."
                sleep 5 &
                wait $! || true
            else
                log_info "(${emoji_prefix:?}) Giving log monitor ${grace}s to process log patterns before exit..."
                sleep "${grace}" &
                wait $! || true
            fi

            # Clear flag so next run is clean
            [ -f /tmp/sentry-log-monitor.error ] && rm -f /tmp/sentry-log-monitor.error || true

            log_warn "(${emoji_prefix:?}) Exiting with status 123."
            exit 123
        fi

        # 7) Containers are found healthy: sleep and loop
        log_success "(${emoji_prefix:?}) All checks passed. Sleeping ${interval}s..."
        sleep "${interval}" &
        wait $! || true
    done
}
sleep 10 &
wait $! || true

echo -e "\e[35m[ Waiting for child services to exit ]\e[0m"

# Run the container logs monitor in the background
if [ "${ENABLE_LOG_MONITOR:-false}" = "true" ]; then
    _log_monitor &
fi

# Run the stack monitor
_stack_monitor
