#!/usr/bin/env bash
###
# File: 20-dind-container-stop.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:56:54 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 21st October 2024 12:29:45 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Stopping DIND container ${dind_continer_name:?} ---"
docker stop --time 120 ${dind_continer_name:?} &>/dev/null || true
echo

echo "--- Removing DIND network ${dind_bridge_network_name:?} ---"
docker network rm "${dind_bridge_network_name:?}" &>/dev/null || true
echo
