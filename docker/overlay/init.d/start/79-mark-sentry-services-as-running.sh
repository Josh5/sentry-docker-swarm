#!/usr/bin/env bash
###
# File: 79-mark-sentry-services-as-running.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:44:30 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 21st October 2024 12:29:30 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Mark Sentry as running ---"
echo "1" >"${SENTRY_DATA_PATH:?}/self_hosted/.z-manager-service-running.txt"
echo
