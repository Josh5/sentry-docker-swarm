#!/usr/bin/env bash
###
# File: 70-start-sentry-services.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:40:21 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Thursday, 28th November 2024 5:07:21 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Checking if Deployment ID of Sentry services has changed ---"
if [ "$(cat ${SENTRY_DATA_PATH:?}/self_hosted/.z-deployment-id.txt 2>/dev/null)" != "${DEPLOYMENT_ID:-}" ]; then
    echo "  - Deployment ID '${DEPLOYMENT_ID:-}' has changed since last run. Previous ID was '$(cat ${SENTRY_DATA_PATH:?}/self_hosted/.z-deployment-id.txt 2>/dev/null)'. Stopping Sentry stack."
    ${docker_compose_cmd:?} down --remove-orphans
else
    echo "  - Deployment ID '${DEPLOYMENT_ID:-}' has not changed."
    if [ "${ALWAYS_FORCE_RECREATE:-}" = "true" ]; then
        echo "  - Stopping Sentry stack due to 'ALWAYS_FORCE_RECREATE' being set to '${ALWAYS_FORCE_RECREATE:-}'."
        ${docker_compose_cmd:?} down --remove-orphans
    fi
fi
echo "${DEPLOYMENT_ID:-}" >"${SENTRY_DATA_PATH:?}/self_hosted/.z-deployment-id.txt"

echo "--- Starting Logging service ---"
if [ "${CUSTOM_LOG_DRIVER:-}" = "fluentd" ]; then
    echo "  - Starting fluentd service (with force-recreate)"
    ${docker_compose_cmd:?} --env-file .env.custom up --detach --force-recreate fluentd
else
    echo "  - No custom logging service configured. Nothing to do."
fi

echo "--- Starting Sentry services ---"
echo "  - Starting existing stack"
${docker_compose_cmd:?} --env-file .env.custom up --detach --remove-orphans
echo "  - Forcing recreation of nginx proxy in stack"
${docker_compose_cmd:?} --env-file .env.custom up --detach --force-recreate nginx
echo
