#!/usr/bin/env bash
###
# File: 70-start-sentry-services.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:40:21 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 21st October 2024 12:29:25 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Starting Sentry services ---"
if [ "${ALWAYS_FORCE_RECREATE:-}" = "true" ]; then
    echo "  - Forcing recreation of whole stack"
    ${docker_cmd:?} compose --env-file .env.custom up --detach --remove-orphans --force-recreate
else
    echo "  - Starting existing stack"
    ${docker_cmd:?} compose --env-file .env.custom up --detach --remove-orphans
    echo "  - Forcing recreation of nginx proxy in stack"
    ${docker_cmd:?} compose --env-file .env.custom up --detach --force-recreate nginx
fi
echo
