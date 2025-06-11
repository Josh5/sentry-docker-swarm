#!/usr/bin/env bash
###
# File: 10-configure-docker-networks.sh
# Project: init.d
# File Created: Monday, 21st October 2024 10:43:23 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Wednesday, 11th June 2025 1:48:25 pm
# Modified By: Josh.5 (jsunnex@gmail.com)
###

echo "--- Ensure Sentry network exists and update compose stack to use it ---"
for i in {1..10}; do
    sentry_net_name=$(docker network ls --filter name=${NETWORK_NAME:?} --format "{{.Name}}" | head -n1 || echo "")
    if [ "X${sentry_net_name:-}" != "X" ]; then
        echo "  - Private network discovered with name ${sentry_net_name:?}"
        echo
        break
    fi
    echo "  - Waiting for network '${NETWORK_NAME}' to appear... (${i}/10)"
    sleep 1
done

if [ "X${sentry_net_name:-}" = "X" ]; then
    echo "  - Failed to discover the sentry private network after 10 seconds. Exit!"
    exit 1
fi
