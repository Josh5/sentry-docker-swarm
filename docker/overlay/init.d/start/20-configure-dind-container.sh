#!/usr/bin/env bash
###
# File: 20-configure-dind-container.sh
# Project: init.d
# File Created: Monday, 21st October 2024 10:37:05 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 1st September 2025 12:14:08 pm
# Modified By: Josh.5 (jsunnex@gmail.com)
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

echo "  - Calculate DIND container CPU limits..."
if [ -n "${DIND_CPU_PERCENT:-}" ]; then
    if [[ "${DIND_CPU_PERCENT:?}" =~ ^[0-9]+$ ]] && [ "${DIND_CPU_PERCENT:?}" -ge 1 ] && [ "${DIND_CPU_PERCENT:?}" -le 100 ]; then
        echo "    - The DIND_CPU_PERCENT variable is a valid number between 1 and 100."
        if [ "${DIND_CPU_PERCENT:?}" = "100" ]; then
            # 100 is not actually a valid number. Lets just drop that down a tad
            DIND_CPU_PERCENT=99
        fi
    else
        echo "    - The DIND_CPU_PERCENT variable is not a valid number between 1 and 100. Defaulting to 75."
        DIND_CPU_PERCENT=75
    fi
else
    echo "    - The DIND_CPU_PERCENT variable has not been provided. Defaulting to 75."
    DIND_CPU_PERCENT=75
fi
TOTAL_CPUS=$(nproc)
echo "    - Calculating CPU Quota from ${DIND_CPU_PERCENT:?}% of a total ${TOTAL_CPUS:?} CPUs"
CPU_PERIOD=100000
CPU_QUOTA=$(echo "${CPU_PERIOD:?} * $(nproc) * 0.${DIND_CPU_PERCENT:?}" | bc)
CPU_QUOTA=${CPU_QUOTA%.*}
echo "    - CPU Quota: ${CPU_QUOTA:?}/${CPU_PERIOD:?}"

echo "  - Configure DIND container run aliases..."
mkdir -p ${dind_cache_path:?}
mkdir -p ${dind_run_path:?}
DIND_RUN_CMD="docker run --privileged -d --rm --name ${dind_continer_name:?} \
    --memory ${DIND_MEMLIMIT:-0} \
    --cpu-shares ${DIND_CPU_SHARES:-512} \
    --cpu-period ${CPU_PERIOD:?} \
    --cpu-quota ${CPU_QUOTA:?} \
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
    docker stop --time 120 "${dind_continer_name}" &>/dev/null || true
    docker rm "${dind_continer_name}" &>/dev/null || true
    mv -fv "${dind_cache_path:?}/new-dind-run-config.env" "${dind_cache_path:?}/current-dind-run-config.env"
elif [ "$(cat ${SENTRY_DATA_PATH:?}/self_hosted/.z-deployment-id.txt 2>/dev/null)" != "${DEPLOYMENT_ID:-}" ]; then
    echo "  - Deployment ID '${DEPLOYMENT_ID:-}' has changed since last run. Previous ID was '$(cat ${SENTRY_DATA_PATH:?}/self_hosted/.z-deployment-id.txt 2>/dev/null)'. Stopping DIND container."
    docker stop --time 120 "${dind_continer_name}" &>/dev/null || true
    docker rm "${dind_continer_name}" &>/dev/null || true
else
    echo "    - Env has not changed."
fi

echo "  - Ensure DIND container is running"
if ! docker ps | grep -q "${dind_continer_name}"; then
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
echo "  - Install required installation dependency packages in DIND container required for install script"
${cmd_prefix:?} sh -c "apk add bash coreutils cgroup-tools git"
echo "  - Install yq tool to edit Sentry config.yml"
wget -q "https://github.com/mikefarah/yq/releases/download/v4.43.1/yq_linux_amd64" \
    -O "/usr/bin/yq"
chmod +x "/usr/bin/yq"
echo
