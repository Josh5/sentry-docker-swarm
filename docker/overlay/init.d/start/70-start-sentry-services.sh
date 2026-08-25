#!/usr/bin/env bash
###
# File: 70-start-sentry-services.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:40:21 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Sunday, 1st December 2024 12:09:21 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

run_sentry_compose_nonfatal() {
    local operation="${1:?}"
    local status
    shift
    if ${docker_compose_cmd:?} "$@"; then
        return 0
    else
        status=$?
    fi
    echo "  - WARNING: ${operation} failed with exit code ${status}. The manager will continue into supervision."
    return 0
}

echo "--- Checking if Deployment ID of Sentry services has changed ---"
if [ "$(cat ${SENTRY_DATA_PATH:?}/self_hosted/.z-deployment-id.txt 2>/dev/null)" != "${DEPLOYMENT_ID:-}" ]; then
    echo "  - Deployment ID '${DEPLOYMENT_ID:-}' has changed since last run. Previous ID was '$(cat ${SENTRY_DATA_PATH:?}/self_hosted/.z-deployment-id.txt 2>/dev/null)'. Stopping Sentry stack."
    run_sentry_compose_nonfatal "Stopping the changed Sentry deployment" down --remove-orphans
elif [ "${WEB_ONLY_MAINTENANCE_MODE:-}" = "true" ]; then
    echo "  - Stopping Sentry stack due to 'WEB_ONLY_MAINTENANCE_MODE' being set to '${WEB_ONLY_MAINTENANCE_MODE:-}'."
    run_sentry_compose_nonfatal "Stopping Sentry for maintenance mode" down --remove-orphans
elif [ "${ALWAYS_FORCE_RECREATE:-}" = "true" ]; then
    echo "  - Stopping Sentry stack due to 'ALWAYS_FORCE_RECREATE' being set to '${ALWAYS_FORCE_RECREATE:-}'."
    run_sentry_compose_nonfatal "Stopping Sentry for forced recreation" down --remove-orphans
else
    echo "  - Deployment ID '${DEPLOYMENT_ID:-}' has not changed."
fi
echo "${DEPLOYMENT_ID:-}" >"${SENTRY_DATA_PATH:?}/self_hosted/.z-deployment-id.txt"

echo "--- Creating custom run script ---"
echo "#!/usr/bin/env bash" >"${SENTRY_DATA_PATH:?}"/self_hosted/sentry-compose.sh
echo "cd $(cd "${SENTRY_DATA_PATH:?}/self_hosted" && pwd)" >>"${SENTRY_DATA_PATH:?}"/self_hosted/sentry-compose.sh
echo "docker compose -f ./docker-compose.yml -f ./docker-compose.custom.yml --env-file .env.custom" ' $@' >>"${SENTRY_DATA_PATH:?}"/self_hosted/sentry-compose.sh
chmod +x "${SENTRY_DATA_PATH:?}"/self_hosted/sentry-compose.sh

echo "--- Starting Logging service ---"
if [ "${CUSTOM_LOG_DRIVER:-}" = "fluentd" ]; then
    echo "  - Starting fluentd service (with force-recreate)"
    run_sentry_compose_nonfatal \
        "Starting the Fluentd service" \
        --env-file .env.custom up --detach --force-recreate fluentd
else
    echo "  - No custom logging service configured. Nothing to do."
fi

echo "--- Starting Sentry services ---"
if [ "${WEB_ONLY_MAINTENANCE_MODE:-}" = "true" ]; then
    echo "  - Starting services in maintenance mode with only minimal services running"
    run_sentry_compose_nonfatal \
        "Starting the maintenance-mode Sentry services" \
        --env-file .env.custom up --detach nginx web
else
    echo "  - Starting existing stack"
    run_sentry_compose_nonfatal \
        "Starting the Sentry stack" \
        --env-file .env.custom up --detach --remove-orphans
    echo "  - Forcing recreation of nginx proxy in stack"
    run_sentry_compose_nonfatal \
        "Recreating the Sentry nginx service" \
        --env-file .env.custom up --detach --force-recreate nginx
fi
unset -f run_sentry_compose_nonfatal
echo
