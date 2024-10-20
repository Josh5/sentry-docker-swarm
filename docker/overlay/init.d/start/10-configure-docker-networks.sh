#!/usr/bin/env bash
###
# File: 10-configure-docker-networks.sh
# Project: init.d
# File Created: Monday, 21st October 2024 10:43:23 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 21st October 2024 12:29:09 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Ensure Sentry network exists and update compose stack to use it ---"
sentry_net_name=$(docker network ls --filter name=${NETWORK_NAME:?} --format "{{.Name}}" || echo "")
if [ "X${sentry_net_name:-}" = "X" ]; then
    echo "  - Failed to discover the sentry private network. Exit!"
    exit 1
fi
echo "  - Private network discovered with name ${sentry_net_name}"
echo
