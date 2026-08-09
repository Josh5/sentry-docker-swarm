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
export fluentd_image_tag="v1.19-debian-1"
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

log_header() { __log_line "🚀 $*"; }
log_subheader() { __log_line "➡️ $*"; }
log_task() { __log_line "⏳ $*"; }
log_step() { __log_line "🔹 $*"; }
log_info() { __log_line "ℹ️ $*"; }
log_warn() { __log_line "⚠️ $*"; }
log_error() { __log_line "❌ $*"; }
log_success() { __log_line "✅ $*"; }

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
_collect_service_log_matches() {
    local service="$1"
    local container_ids="$2"
    local patterns="$3"
    local scan_since="$4"
    local scan_until="$5"
    local dind_docker_host="$6"
    local result_file="$7"
    local container_id container_log_file pattern match_count

    : >"$result_file"
    if [ -z "$container_ids" ]; then
        printf 'NO_CONTAINERS\n' >>"$result_file"
        return 0
    fi

    for container_id in $container_ids; do
        container_log_file="${result_file}.${container_id}.logs"
        if ! timeout 30 docker --host "$dind_docker_host" logs \
            --since "$scan_since" --until "$scan_until" \
            "$container_id" >"$container_log_file" 2>&1; then
            printf 'FETCH_ERROR\t%s\n' "$container_id" >>"$result_file"
            rm -f "$container_log_file"
            continue
        fi

        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            match_count=$(grep -cE -- "$pattern" "$container_log_file" || true)
            case "$match_count" in
            '' | *[!0-9]*)
                printf 'SCAN_ERROR\t%s\n' "$container_id" >>"$result_file"
                ;;
            0) ;;
            *) printf 'MATCH\t%s\t%s\t%s\n' "$container_id" "$match_count" "$pattern" >>"$result_file" ;;
            esac
        done <<<"$patterns"
        rm -f "$container_log_file"
    done
}

_log_monitor() {
    local emoji_prefix="🔎📄"
    log_header "Starting log monitor (${emoji_prefix})"
    sleep 10 &
    wait $! || true

    local interval=60
    local initial_lookback=180
    local max_parallel_collectors=4
    local log_monitor_config_file="/defaults/log-monitor/config.json"
    local dind_docker_host="unix://${dind_run_path:?}/docker.sock"
    local -A service_error_checks=()
    local -A service_alert_levels=()
    local -A service_log_cursors=()

    while true; do
        local scan_until pass_started
        scan_until=$(date +%s)
        pass_started="$scan_until"
        log_subheader "(${emoji_prefix}) Collecting and checking new service logs through $(date -d "@${scan_until}")"

        # Gather the Compose service list and build one pattern collection per
        # service. A service matching multiple config rules is still fetched
        # only once.
        local -a all_services=()
        mapfile -t all_services < <(${docker_compose_cmd:?} config --services 2>/dev/null || true)
        if [ "${#all_services[@]}" -eq 0 ]; then
            log_warn "(${emoji_prefix}) Compose returned no services for log monitoring; preserving cursors and retrying later."
            sleep "$interval" &
            wait $! || true
            continue
        fi

        local service_count
        if ! service_count=$(yq e 'length' "${log_monitor_config_file:?}"); then
            log_warn "(${emoji_prefix}) Unable to read the log-monitor configuration; preserving cursors and retrying later."
            sleep "$interval" &
            wait $! || true
            continue
        fi
        local -A monitored_services=()
        local -A service_patterns=()

        for i in $(seq 0 $((service_count - 1))); do
            local svc_regex
            svc_regex=$(yq e -r ".[$i].service" "$log_monitor_config_file")
            local patterns
            patterns=$(yq e -r ".[$i].patterns[]" "$log_monitor_config_file" 2>/dev/null || true)
            [ -z "$patterns" ] && continue

            local svc
            for svc in "${all_services[@]}"; do
                if [[ "$svc" =~ $svc_regex ]]; then
                    monitored_services["$svc"]=1
                    if [ -n "${service_patterns[$svc]:-}" ]; then
                        service_patterns["$svc"]+=$'\n'
                    fi
                    service_patterns["$svc"]+="$patterns"
                fi
            done
        done

        # Query the inner Docker daemon once for the complete running
        # container-to-Compose-service mapping.
        local container_inventory
        if ! container_inventory=$(timeout 15 docker --host "$dind_docker_host" ps \
            --format '{{.ID}}|{{.Label "com.docker.compose.service"}}' 2>/dev/null); then
            log_warn "(${emoji_prefix}) Unable to query the DinD container inventory; preserving log cursors and retrying later."
            sleep "$interval" &
            wait $! || true
            continue
        fi

        local -A service_container_ids=()
        local container_id container_service
        while IFS='|' read -r container_id container_service; do
            [ -n "$container_id" ] && [ -n "$container_service" ] || continue
            service_container_ids["$container_service"]+="${service_container_ids[$container_service]:+ }${container_id}"
        done <<<"$container_inventory"

        local pass_dir
        pass_dir=$(mktemp -d /tmp/sentry-log-monitor.XXXXXX)
        local -a collector_pids=()
        local monitored_service service_scan_since result_file pid
        for monitored_service in "${!monitored_services[@]}"; do
            service_scan_since="${service_log_cursors[$monitored_service]:-$((scan_until - initial_lookback))}"
            result_file="${pass_dir}/${monitored_service}.result"
            log_step "(${emoji_prefix}) Collecting '${monitored_service}' logs from ${service_scan_since} through ${scan_until}"
            _collect_service_log_matches \
                "$monitored_service" \
                "${service_container_ids[$monitored_service]:-}" \
                "${service_patterns[$monitored_service]:-}" \
                "$service_scan_since" "$scan_until" \
                "$dind_docker_host" "$result_file" &
            collector_pids+=("$!")

            if [ "${#collector_pids[@]}" -ge "$max_parallel_collectors" ]; then
                for pid in "${collector_pids[@]}"; do
                    wait "$pid" || true
                done
                collector_pids=()
            fi
        done
        for pid in "${collector_pids[@]}"; do
            wait "$pid" || true
        done

        # Collate worker results in the main log-monitor process so alert and
        # cursor state never needs to be shared between background jobs.
        local -A service_match_counts=()
        local -A service_error_descriptions=()
        local result_type match_count pattern collection_failed
        local cid_short
        for monitored_service in "${!monitored_services[@]}"; do
            result_file="${pass_dir}/${monitored_service}.result"
            collection_failed=false
            while IFS=$'\t' read -r result_type container_id match_count pattern; do
                case "$result_type" in
                MATCH)
                    service_match_counts["$monitored_service"]=$((${service_match_counts[$monitored_service]:-0} + match_count))
                    cid_short="${container_id:0:12}"
                    service_error_descriptions["$monitored_service"]+="• ${monitored_service} (${cid_short}) — ${match_count} line(s) matched: ${pattern}\\n"
                    ;;
                FETCH_ERROR | SCAN_ERROR | NO_CONTAINERS)
                    collection_failed=true
                    ;;
                esac
            done <"$result_file"

            if [ "$collection_failed" = "true" ]; then
                log_warn "(${emoji_prefix}) Log collection or scanning failed for '${monitored_service}'; preserving its cursor and incident state."
                continue
            fi
            service_log_cursors["$monitored_service"]="$scan_until"

            local matches consecutive_error_checks alert_level
            local errors_description desc_trimmed notification_message
            matches="${service_match_counts[$monitored_service]:-0}"
            alert_level="${service_alert_levels[$monitored_service]:-none}"

            if [ "$matches" -gt 0 ]; then
                consecutive_error_checks=$((${service_error_checks[$monitored_service]:-0} + 1))
                service_error_checks["$monitored_service"]="$consecutive_error_checks"
                errors_description="${service_error_descriptions[$monitored_service]:-}"
                desc_trimmed="${errors_description%\\n}"
                notification_message="${matches} new log line(s) matched configured error patterns: ${desc_trimmed}"

                if [ "$consecutive_error_checks" -ge 3 ] && [ "$alert_level" != "error" ]; then
                    service_alert_levels["$monitored_service"]="error"
                    log_error "(${emoji_prefix}) ${monitored_service} produced matching errors in three consecutive log intervals; sending one error notification."
                    _send_notification "error" "sentry-log-monitor" "log-patterns-${monitored_service}" "Service '${monitored_service}': ${notification_message}" "trigger"
                elif [ "$consecutive_error_checks" -ge 2 ] && [ "$alert_level" = "none" ]; then
                    service_alert_levels["$monitored_service"]="warning"
                    log_warn "(${emoji_prefix}) ${monitored_service} produced matching errors in two consecutive log intervals; sending one warning notification."
                    _send_notification "warning" "sentry-log-monitor" "log-patterns-${monitored_service}" "Service '${monitored_service}': ${notification_message}" "trigger"
                else
                    log_warn "(${emoji_prefix}) ${monitored_service}: ${matches} new matching log line(s) found (observation ${consecutive_error_checks})."
                fi
            else
                if [ "$alert_level" != "none" ]; then
                    _send_notification "$alert_level" "sentry-log-monitor" "log-patterns-${monitored_service}" "No new configured error patterns matched service '${monitored_service}'." "resolve"
                fi
                unset 'service_error_checks[$monitored_service]'
                unset 'service_alert_levels[$monitored_service]'
            fi
        done

        rm -rf "$pass_dir"

        # Resolve and forget incidents for services removed from the monitor
        # configuration during a manager update.
        local previously_monitored_service
        for previously_monitored_service in "${!service_alert_levels[@]}"; do
            if [ -z "${monitored_services[$previously_monitored_service]+configured}" ]; then
                _send_notification "${service_alert_levels[$previously_monitored_service]}" \
                    "sentry-log-monitor" "log-patterns-${previously_monitored_service}" \
                    "Service '${previously_monitored_service}' is no longer included in log monitoring." "resolve"
                unset 'service_error_checks[$previously_monitored_service]'
                unset 'service_alert_levels[$previously_monitored_service]'
                unset 'service_log_cursors[$previously_monitored_service]'
            fi
        done

        log_success "(${emoji_prefix}) Log pass completed in $(($(date +%s) - pass_started))s. Sleeping ${interval}s..."
        sleep "${interval}" &
        wait $! || true
    done
}

# Supervisor policy is intentionally fixed so every deployment receives the
# same recovery behavior without operator tuning.
readonly MONITOR_CHECK_INTERVAL=30
readonly SERVICE_RECHECK_DELAY=120
readonly SERVICE_FAILURE_WINDOW=600
readonly SERVICE_WARNING_OBSERVATION=2
readonly SERVICE_ERROR_OBSERVATION=3
readonly DIND_PROBE_TIMEOUT=10

declare -A SERVICE_FAILURE_HISTORY=()
declare -A SERVICE_ALERT_LEVEL=()
declare -A SERVICE_NEXT_CHECK_AT=()
declare -A SERVICE_RESTART_TOTAL=()
DIND_FAILURE_COUNT=0
DIND_ALERT_LEVEL="none"
DIND_NEXT_CHECK_AT=0
COMPOSE_CONFIG_FAILURE_COUNT=0
COMPOSE_CONFIG_ALERT_LEVEL="none"

_send_notification() {
    /bin/sh /defaults/notifications/send.sh "$@" ||
        log_error "Notification helper failed for component '${2:-unknown}'."
}

_wait_for_dind() {
    local attempt=1
    while [ "$attempt" -le 30 ]; do
        if timeout "${DIND_PROBE_TIMEOUT}" docker exec "${dind_continer_name:?}" docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 2 &
        wait $! || true
        attempt=$((attempt + 1))
    done
    return 1
}

_recover_dind() {
    log_warn "DinD is not responding. Recreating it and its Sentry services."

    docker rm --force "${dind_continer_name:?}" >/dev/null 2>&1 || true
    if ! rm -f "${dind_run_path:?}/docker.sock"; then
        log_error "Failed to remove the stale DinD socket."
        return 1
    fi
    if ! ${DIND_RUN_CMD:?} >/dev/null; then
        log_error "Failed to recreate the DinD container."
        return 1
    fi
    if ! ${DIND_NET_CONN_CMD:?} >/dev/null; then
        log_error "Failed to reconnect DinD to the Sentry network."
        return 1
    fi

    if ! _wait_for_dind; then
        log_error "Recreated DinD container did not become ready."
        return 1
    fi

    # The cgroup and tools live in the DinD container namespace and must be
    # restored after the container itself is recreated.
    if ! ${cmd_prefix:?} sh -c "apk add --no-cache bash coreutils cgroup-tools git >/dev/null"; then
        log_error "Failed to restore required DinD packages."
        return 1
    fi
    if ! ${cmd_prefix:?} cgcreate -g cpu:/sentry-backend-services; then
        log_error "Failed to restore the Sentry service cgroup."
        return 1
    fi
    if ! ${cmd_prefix:?} cgset -r cpu.weight="${DIND_CPU_SHARES:-512}" /sentry-backend-services; then
        log_error "Failed to restore the Sentry service CPU weight."
        return 1
    fi
    if ! ${cmd_prefix:?} cgset -r cpu.max="${SERVICES_CPU_QUOTA:?} ${CPU_PERIOD:?}" /sentry-backend-services; then
        log_error "Failed to restore the Sentry service CPU quota."
        return 1
    fi

    if ! ${docker_compose_cmd:?} --env-file .env.custom up --detach --remove-orphans; then
        log_error "DinD recovered, but Compose failed to reconcile the Sentry services."
        return 1
    fi
    return 0
}

_record_and_recover_service() {
    local service="$1"
    local status="$2"
    local needs_restart="$3"
    local now history valid_history count timestamp alert_level
    now=$(date +%s)

    history="${SERVICE_FAILURE_HISTORY[$service]:-}"
    valid_history=""
    count=0
    for timestamp in $history; do
        if [ $((now - timestamp)) -le "$SERVICE_FAILURE_WINDOW" ]; then
            valid_history="${valid_history}${valid_history:+ }${timestamp}"
            count=$((count + 1))
        fi
    done
    valid_history="${valid_history}${valid_history:+ }${now}"
    count=$((count + 1))
    SERVICE_FAILURE_HISTORY["$service"]="$valid_history"
    alert_level="${SERVICE_ALERT_LEVEL[$service]:-none}"

    if [ "$count" -ge "$SERVICE_ERROR_OBSERVATION" ] && [ "$alert_level" != "error" ]; then
        SERVICE_ALERT_LEVEL["$service"]="error"
        log_error "Service '${service}' failed ${count} times within ${SERVICE_FAILURE_WINDOW}s; human intervention is required."
        _send_notification "error" "sentry-service" "service-${service}" "Service '${service}' is repeatedly failing (${status}). Automatic recovery will continue." "trigger"
    elif [ "$count" -ge "$SERVICE_WARNING_OBSERVATION" ] && [ "$alert_level" = "none" ]; then
        SERVICE_ALERT_LEVEL["$service"]="warning"
        log_warn "Service '${service}' failed twice within ${SERVICE_FAILURE_WINDOW}s; sending a warning."
        _send_notification "warning" "sentry-service" "service-${service}" "Service '${service}' failed again after automatic recovery (${status})." "trigger"
    fi

    if [ "${needs_restart}" = "true" ]; then
        log_task "Restarting failed service '${service}' (observation ${count}): ${status}"
        if ! ${docker_compose_cmd:?} --env-file .env.custom restart "$service"; then
            log_warn "Direct restart of '${service}' failed; asking Compose to recreate it."
            if ! ${docker_compose_cmd:?} --env-file .env.custom up --detach --no-deps "$service"; then
                log_error "Failed to recover '${service}'; the supervisor will retry after the observation period."
            fi
        fi
    else
        log_warn "Service '${service}' restarted between checks (${status}); monitoring it before taking further action."
    fi

    SERVICE_NEXT_CHECK_AT["$service"]=$(($(date +%s) + SERVICE_RECHECK_DELAY))
}

_record_service_recovery() {
    local service="$1"
    local alert_level="${SERVICE_ALERT_LEVEL[$service]:-none}"

    if [ "${alert_level}" != "none" ]; then
        log_success "Service '${service}' remained healthy after recovery."
        _send_notification "${alert_level}" "sentry-service" "service-${service}" "Service '${service}' is healthy and stable again." "resolve"
    fi

    unset 'SERVICE_FAILURE_HISTORY[$service]'
    unset 'SERVICE_ALERT_LEVEL[$service]'
    unset 'SERVICE_NEXT_CHECK_AT[$service]'
}

_stack_monitor() {
    local emoji_prefix="👀🌡️"
    local ignored_services="geoipupdate|place_holder"
    local services service lines healthy state health status now
    local container_ids container_id restart_count restart_total previous_restart_total
    local auto_restart_detected needs_restart
    local -a failed_services=()
    local -a failed_statuses=()
    local -a failed_needs_restart=()

    log_header "Starting active stack supervisor (${emoji_prefix})"
    cd "${SENTRY_DATA_PATH:?}/self_hosted"

    while true; do
        log_subheader "(${emoji_prefix}) Running DinD and Compose health checks at $(date)"
        now=$(date +%s)

        if [ "$now" -lt "$DIND_NEXT_CHECK_AT" ]; then
            log_info "DinD recovery observation period is active for $((DIND_NEXT_CHECK_AT - now))s."
            sleep "${MONITOR_CHECK_INTERVAL}" &
            wait $! || true
            continue
        fi

        if [ "$now" -ge "$DIND_NEXT_CHECK_AT" ]; then
            if timeout "${DIND_PROBE_TIMEOUT}" docker exec "${dind_continer_name:?}" docker info >/dev/null 2>&1; then
                if [ "$DIND_ALERT_LEVEL" != "none" ]; then
                    _send_notification "${DIND_ALERT_LEVEL}" "sentry-dind" "dind" "DinD and its Sentry services are responding again." "resolve"
                fi
                DIND_FAILURE_COUNT=0
                DIND_ALERT_LEVEL="none"
                DIND_NEXT_CHECK_AT=0
            else
                DIND_FAILURE_COUNT=$((DIND_FAILURE_COUNT + 1))
                if [ "$DIND_FAILURE_COUNT" -ge 3 ] && [ "$DIND_ALERT_LEVEL" != "error" ]; then
                    DIND_ALERT_LEVEL="error"
                    _send_notification "error" "sentry-dind" "dind" "DinD remains unavailable after repeated automatic recovery attempts. Automatic recovery will continue." "trigger"
                elif [ "$DIND_FAILURE_COUNT" -ge 2 ] && [ "$DIND_ALERT_LEVEL" = "none" ]; then
                    DIND_ALERT_LEVEL="warning"
                    _send_notification "warning" "sentry-dind" "dind" "DinD is still unavailable after the first automatic recovery attempt." "trigger"
                fi

                if _recover_dind; then
                    log_info "DinD recreation completed; waiting ${SERVICE_RECHECK_DELAY}s before verifying stability."
                else
                    log_error "DinD recovery did not complete; the supervisor will keep retrying."
                fi
                DIND_NEXT_CHECK_AT=$(($(date +%s) + SERVICE_RECHECK_DELAY))
                sleep "${MONITOR_CHECK_INTERVAL}" &
                wait $! || true
                continue
            fi
        fi

        if [ "${WEB_ONLY_MAINTENANCE_MODE:-}" = "true" ]; then
            services="web nginx"
        else
            services="$(${docker_compose_cmd:?} config --services 2>/dev/null | grep -Ev "${ignored_services:?}" || true)"
        fi

        if [ -z "$services" ]; then
            COMPOSE_CONFIG_FAILURE_COUNT=$((COMPOSE_CONFIG_FAILURE_COUNT + 1))
            log_error "Compose returned no monitored services. The supervisor will retry."
            if [ "$COMPOSE_CONFIG_FAILURE_COUNT" -ge 3 ] && [ "$COMPOSE_CONFIG_ALERT_LEVEL" != "error" ]; then
                _send_notification "error" "sentry-manager" "compose-config" "Compose returned no monitored Sentry services. The manager will keep retrying." "trigger"
                COMPOSE_CONFIG_ALERT_LEVEL="error"
            elif [ "$COMPOSE_CONFIG_FAILURE_COUNT" -ge 2 ] && [ "$COMPOSE_CONFIG_ALERT_LEVEL" = "none" ]; then
                _send_notification "warning" "sentry-manager" "compose-config" "Compose service discovery failed again. The manager will keep retrying." "trigger"
                COMPOSE_CONFIG_ALERT_LEVEL="warning"
            fi
            sleep "${MONITOR_CHECK_INTERVAL}" &
            wait $! || true
            continue
        elif [ "$COMPOSE_CONFIG_ALERT_LEVEL" != "none" ]; then
            _send_notification "${COMPOSE_CONFIG_ALERT_LEVEL}" "sentry-manager" "compose-config" "Compose service discovery is working again." "resolve"
            COMPOSE_CONFIG_FAILURE_COUNT=0
            COMPOSE_CONFIG_ALERT_LEVEL="none"
        else
            COMPOSE_CONFIG_FAILURE_COUNT=0
        fi

        failed_services=()
        failed_statuses=()
        failed_needs_restart=()

        # Snapshot every service before performing any recovery actions.
        for service in $services; do
            if [ "$now" -lt "${SERVICE_NEXT_CHECK_AT[$service]:-0}" ]; then
                continue
            fi

            lines="$(${docker_compose_cmd:?} ps --all --format '{{.Service}}|{{.State}}|{{.Health}}' "$service" 2>/dev/null || true)"
            healthy=true
            status="No running container found"
            [ -n "$lines" ] || healthy=false
            while IFS='|' read -r _ state health; do
                [ -n "$state" ] || continue
                if [ "$state" != "running" ] || [ "$health" = "unhealthy" ]; then
                    healthy=false
                    status="state=${state}${health:+, health=${health}}"
                fi
            done <<<"$lines"

            restart_total=0
            container_ids="$(${docker_compose_cmd:?} ps --all -q "$service" 2>/dev/null || true)"
            for container_id in $container_ids; do
                restart_count="$(${docker_cmd:?} inspect --format '{{.RestartCount}}' "$container_id" 2>/dev/null || printf '0')"
                case "$restart_count" in
                '' | *[!0-9]*) restart_count=0 ;;
                esac
                restart_total=$((restart_total + restart_count))
            done

            previous_restart_total="${SERVICE_RESTART_TOTAL[$service]:-}"
            auto_restart_detected=false
            if [ -n "$previous_restart_total" ] && [ "$restart_total" -gt "$previous_restart_total" ]; then
                auto_restart_detected=true
                status="Docker restart count increased from ${previous_restart_total} to ${restart_total}"
            fi
            SERVICE_RESTART_TOTAL["$service"]="$restart_total"

            if [ "$healthy" = "true" ] && [ "$auto_restart_detected" = "false" ]; then
                if [ -n "${SERVICE_FAILURE_HISTORY[$service]:-}" ]; then
                    _record_service_recovery "$service"
                fi
                continue
            fi

            needs_restart=true
            [ "$healthy" = "true" ] && needs_restart=false
            failed_services+=("$service")
            failed_statuses+=("$status")
            failed_needs_restart+=("$needs_restart")
        done

        # Recover each failed service independently after the complete snapshot.
        local i
        for i in "${!failed_services[@]}"; do
            _record_and_recover_service "${failed_services[$i]}" "${failed_statuses[$i]}" "${failed_needs_restart[$i]}"
        done

        log_success "(${emoji_prefix}) Health check complete. Sleeping ${MONITOR_CHECK_INTERVAL}s."
        sleep "${MONITOR_CHECK_INTERVAL}" &
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
