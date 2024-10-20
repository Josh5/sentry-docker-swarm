#!/usr/bin/env bash
###
# File: 10-mark-sentry-services-as-stopped.sh
# Project: stop
# File Created: Monday, 21st October 2024 11:59:53 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 21st October 2024 12:29:42 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Removing service running lockfile ---"
mkdir -p ${SENTRY_DATA_PATH:?}/self_hosted
rm -f "${SENTRY_DATA_PATH:?}/self_hosted/.z-manager-service-running.txt"
echo
