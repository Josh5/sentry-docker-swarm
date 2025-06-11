#!/usr/bin/env bash
###
# File: entrypoint.sh
# Project: overlay
# File Created: Friday, 18th October 2024 5:05:51 pm
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Wednesday, 11th June 2025 2:50:04 pm
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
    echo
    echo -e "\e[35m[ Starting log monitor ]\e[0m"

    local log_monitor_config_file="/defaults/log-monitor-config.json"
    local log_monitor_since="3m"

    while true; do
        local service_count service container_ids available_services
        service_count=$(yq e 'length' "${log_monitor_config_file:?}")

        # Get all services from compose stack
        available_services=$(${docker_compose_cmd:?} config --services)

        for i in $(seq 0 $((service_count - 1))); do
            log_monitor_service_pattern=$(yq e ".[$i].service" "$log_monitor_config_file")
            log_monitor_patterns=$(yq e ".[$i].patterns[]" "$log_monitor_config_file")

            # Match pattern against available services
            for svc in ${available_services}; do
                if [[ "$svc" == $log_monitor_service_pattern ]]; then
                    log_monitor_container_ids=$(${docker_compose_cmd:?} ps -q "$svc" || true)
                    [ -z "${log_monitor_container_ids}" ] && continue

                    for container_id in ${log_monitor_container_ids}; do
                        ${docker_cmd:?} logs --since "$log_monitor_since" "$container_id" 2>&1 | while IFS= read -r log_line; do
                            while IFS= read -r pattern; do
                                if echo "$log_line" | grep -qE "$pattern"; then
                                    echo
                                    echo -e "\e[31m[ Log monitor detected error in ${svc}: '${pattern}' matched ]\e[0m"

                                    if [ "${SEND_WEBHOOK_ON_ERRORS_IN_LOGS:-}" != "" ]; then
                                        wget -qO- --method POST \
                                            --body-data "Log monitor error in ${svc}: ${pattern}" \
                                            "${SEND_WEBHOOK_ON_ERRORS_IN_LOGS}" || echo -e "\e[31m[ Failed to send webhook ]\e[0m"
                                    fi

                                    if [ "${EXIT_ON_ERRORS_IN_LOGS:-}" = "true" ]; then
                                        touch /tmp/sentry-log-monitor.error
                                    fi
                                fi
                            done <<<"${log_monitor_patterns}"
                        done
                    done
                fi
            done
        done

        sleep 30
    done
}

_stack_monitor() {
    echo
    echo -e "\e[35m[ Waiting for child services to exit ]\e[0m"
    cd ${SENTRY_DATA_PATH:?}/self_hosted
    while true; do
        # Check if any service has exited with a non-zero status code
        echo "  - Check if any service has exited with a non-zero status code ---"
        ignored_services="geoipupdate|place_holder"
        exited_services=$(${docker_compose_cmd:?} ps --all --filter "status=exited" | grep -v "^NAME" | grep -v "Exit 0" | grep -vE "${ignored_services:?}" || true)
        if [ "X${exited_services}" != "X" ]; then
            echo "      - Some services have exited with a non-zero status. Exit!"
            exit 123
        fi

        # Check for flag set by error strings being found in the container logs
        if [ -f /tmp/sentry-log-monitor.error ]; then
            echo "  - Error flag file detected from log monitor. Exit!"
            rm -f /tmp/sentry-log-monitor.error
            exit 123
        fi

        # Check if the main services have exited
        echo "  - Check that the main services are still up ---"
        if [ "${WEB_ONLY_MAINTENANCE_MODE:-}" = "true" ]; then
            services="web nginx"
        else
            services="$(${docker_compose_cmd:?} config --services | grep -vE "${ignored_services:?}")"
        fi
        # Loop through each service to check its status
        for service in $services; do
            # Use docker compose ps to check if the service is running
            service_status=$(${docker_compose_cmd:?} ps --format "table {{.Service}} {{.Status}}" | grep $service || true)
            case $service_status in
            *Up*)
                echo "      - Service $service is up and running at $(date)."
                continue
                ;;
            *)
                echo "      - Service $service found NOT running at $(date). Exit!"
                exit 123
                ;;
            esac
        done
        sleep 60 &
        wait $!
        echo
    done
}
sleep 10 &
wait $!

# Run the container logs monitor in the background
if [ "${ENABLE_LOG_MONITOR:-false}" = "true" ]; then
    _log_monitor &
fi

# Run the stack monitor
_stack_monitor
