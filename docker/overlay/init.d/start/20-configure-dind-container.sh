#!/usr/bin/env bash
###
# File: 20-configure-dind-container.sh
# Project: init.d
# File Created: Monday, 21st October 2024 10:37:05 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Thursday, 28th November 2024 4:47:17 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Configure DIND ---"
echo "  - Ensure DIND network exists..."
existing_network=$(docker network ls 2>/dev/null | grep "${dind_bridge_network_name:?}" || echo "")
if [ "X${existing_network}" = "X" ]; then
    echo "    - Creating private network for DIND container..."
    docker network create -d bridge "${dind_bridge_network_name:?}"
else
    echo "    - A private network for DIND named ${dind_bridge_network_name:?} already exists!"
fi
echo

echo "  - Configure DIND container run aliases..."
mkdir -p ${dind_cache_path:?}
mkdir -p ${dind_run_path:?}
# Calculate 90% of the available vCPUs
DIND_CPULIMIT=$(echo "$(nproc) * 0.9" | bc)
DIND_RUN_CMD="docker run --privileged -d --rm --name ${dind_continer_name:?} \
    --memory ${DIND_MEMLIMIT:-0} \
    --cpus $(printf "%.1f" "${DIND_CPULIMIT:?}") \
    --cpu-shares ${DIND_CPU_SHARES:-512} \
    --env DOCKER_DRIVER=overlay2 \
    --volume ${dind_cache_path:?}:/var/lib/docker \
    --volume ${dind_run_path:?}:/var/run \
    --volume ${SENTRY_DATA_PATH:?}:${SENTRY_DATA_PATH:?} \
    --network ${dind_bridge_network_name:?} \
    --network-alias ${dind_continer_name:?} \
    --publish 9000:9000 \
    docker:${docker_version:?}-dind"
DIND_NET_CONN_CMD="docker network connect --alias ${dind_continer_name:?} ${sentry_net_name:?} ${dind_continer_name:?}"

echo "  - Writing DIND container config to env file"
echo "" >${dind_cache_path:?}/new-dind-run-config.env
echo "docker_version=${docker_version:?}" >>${dind_cache_path:?}/new-dind-run-config.env
echo "DIND_RUN_CMD=${DIND_RUN_CMD:?}" >>${dind_cache_path:?}/new-dind-run-config.env
echo "DIND_NET_CONN_CMD=${DIND_NET_CONN_CMD:?}" >>${dind_cache_path:?}/new-dind-run-config.env
#cat ${dind_cache_path:?}/new-dind-run-config.env

echo "  - Checking if config has changed since last run"
if ! cmp -s "${dind_cache_path:?}/new-dind-run-config.env" "${dind_cache_path:?}/current-dind-run-config.env"; then
    echo "    - Env has changed. Stopping up old dind container due to possible config update"
    docker stop --time 120 ${dind_continer_name} &>/dev/null || true
    docker rm ${dind_continer_name} &>/dev/null || true
    mv -fv "${dind_cache_path:?}/new-dind-run-config.env" "${dind_cache_path:?}/current-dind-run-config.env"
else
    echo "    - Env has not changed."
fi

echo "  - Ensure DIND container is running"
if ! docker ps | grep -q ${dind_continer_name}; then
    echo "    - Fetching latest docker in docker image 'docker:${docker_version:?}-dind'"
    docker pull docker:${docker_version:?}-dind
    echo

    echo "    - Creating DIND container"
    rm -rf ${dind_run_path}/*
    ${DIND_RUN_CMD:?}
    sleep 5 &
    wait $!
    echo
else
    echo "    - DIND container already running"
fi

echo "--- Install Sentry installation and configuration dependencies into DIND container ---"
echo "  - Install bash and coreutils packages in DIND container required for install script"
${cmd_prefix:?} sh -c "apk add bash coreutils"
echo "  - Install yq tool to endit Sentry config.yml"
wget -q "https://github.com/mikefarah/yq/releases/download/v4.43.1/yq_linux_amd64" \
    -O "/usr/bin/yq"
chmod +x "/usr/bin/yq"
echo
