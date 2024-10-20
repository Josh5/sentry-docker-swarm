#!/usr/bin/env bash
###
# File: 10-configure-directories.sh
# Project: init.d
# File Created: Monday, 21st October 2024 10:37:33 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 21st October 2024 12:29:05 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Create data directories ---"
mkdir -p \
    ${SENTRY_DATA_PATH:?}/self_hosted \
    ${SENTRY_DATA_PATH:?}/update_backups
echo
