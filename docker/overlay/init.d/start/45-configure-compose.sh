#!/usr/bin/env bash
###
# File: 45-configure-compose.sh
# Project: start
# File Created: Monday, 21st October 2024 10:19:15 pm
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Thursday, 28th November 2024 11:59:36 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Create backup of original docker-compose.yml file ---"
if [ ! -f "${SENTRY_DATA_PATH}/self_hosted/docker-compose.bak.yml" ]; then
    cp -f "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.bak.yml"
fi
cp -f "${SENTRY_DATA_PATH}/self_hosted/docker-compose.bak.yml" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"

echo "--- Create custom docker-compose.custom.yml file for new config ---"
echo "" >"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
echo "" >"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
compose_services="$(${docker_cmd:?} compose -f ./docker-compose.yml config --services)"

# Create custom network
echo "  - Ensure custom sentry network '${custom_docker_network_name:?}' exists."
existing_sentry_stack_network=$(${docker_cmd:?} network ls 2>/dev/null | grep "${custom_docker_network_name:?}" || echo "")
if [ "X${existing_sentry_stack_network}" = "X" ]; then
    echo "    - Creating private network for sentry services..."
    ${docker_cmd:?} network create -d bridge "${custom_docker_network_name:?}"
else
    echo "    - A private network for the sentry services named ${custom_docker_network_name:?} already exists."
fi
echo "  - Configure all services to use the custom external docker network."
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
# Use a custom external network as the stacks default nework
networks:
  default:
    name: ${custom_docker_network_name:?}
    external: true

EOF
echo "networks/default/name/${custom_docker_network_name:?}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"

# Use env_file
echo "  - Configure all services to read .env.custom"
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-env-import: &env-import
  env_file: [.env.custom]

EOF
echo "x-env-import/env_file/.env.custom" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"

# Logging driver
echo "  - Configure services logging driver"
if [ "${CUSTOM_LOG_DRIVER:-}" = "json-file" ]; then
    echo "    - Configure Docker Compose to use json-file log driver for all services."
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-logging-base: &logging-base
  logging:
    driver: json-file
    options:
      max-size: 10m
      max-file: 10

EOF
    echo "x-logging-base/logging/driver/json-file/max-size/10m/max-file/10" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
elif [ "${CUSTOM_LOG_DRIVER:-}" = "fluentd" ]; then
    echo "    - Configure Docker Compose to use fluentd log driver for all services."
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-logging-base: &logging-base
  logging:
    driver: fluentd
    options:
      fluentd-address: localhost:24224
      tag: sentry

EOF
    echo "x-logging-base/logging/driver/fluentd/fluentd-address/localhost:24224/tag/sentry" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
else
    echo "    - Configure Docker Compose to use local log driver for all services."
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-logging-base: &logging-base
  logging:
    driver: local
    options:
      max-size: 20m
      max-file: 5

EOF
    echo "x-logging-base/logging/driver/local/max-size/20m/max-file/5" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
fi

# Memory limits
echo "  - Configure services memory limits in docker-compose.custom.yml"
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-mem-limits: &mem-limits
  mem_limit: ${DIND_MEMLIMIT:-0}

EOF
echo "x-mem-limits/mem_limit/${DIND_MEMLIMIT:-0}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"

# CPU limits
CPU_PERIOD=100000
CPU_QUOTA=$(echo "${CPU_PERIOD:?} * $(nproc) * 0.75" | bc)
CPU_QUOTA=${CPU_QUOTA%.*}
echo "  - Configure docker stack CPU cgroup"
${cmd_prefix:?} cgcreate -g cpu:/sentry-stack-cgroup
echo "  - Apply CPU Share limits ${DIND_CPU_SHARES:-512}"
${cmd_prefix:?} cgset -r cpu.weight="${DIND_CPU_SHARES:-512}" /sentry-stack-cgroup
echo "  - Apply CPU Max quota as ${CPU_QUOTA:?} ${CPU_PERIOD:?}"
${cmd_prefix:?} cgset -r cpu.max="${CPU_QUOTA:?} ${CPU_PERIOD:?}" /sentry-stack-cgroup
echo "  - Configure services cgroup_parent as /sentry-stack-cgroup in docker-compose.custom.yml"
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-cpu-limits: &cpu-limits
  cgroup_parent: /sentry-stack-cgroup

x-cpu-shares-web: &cpu-shares-web
  cpu_shares: 2048

EOF
echo "x-cpu-limits/cpus/${CPU_QUOTA:?}-${CPU_PERIOD:?}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
echo "x-cpu-limits/cpu_shares/${DIND_CPU_SHARES:-512}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"

# Consolidate
echo "  - Write custom config to all services"
echo "services:" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
for service in ${compose_services:?}; do
    echo "    - Applying to service '${service:?}'."
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
  ${service:?}:
    <<: 
      - *env-import
      - *logging-base
      - *mem-limits
EOF
    # Check if the service name is either the web, nginx or relay. Give these a higher cpu share.
    # For all other services, limit them to whatever is configured with DIND_CPU_SHARES and a cpu.max of 75% of total CPU on host.
    if [[ "${service:?}" == "web" || "${service:?}" == "nginx" || "${service:?}" == "relay" ]]; then
        echo "      - *cpu-shares-web" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
    else
        echo "      - *cpu-limits" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
    fi
done

# Configure logging service
echo "  - Configure fluentd sidecar service"
if [ "${CUSTOM_LOG_DRIVER:-}" = "fluentd" ]; then
    echo "    - Adding custom fluentd container to services."
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"

  fluentd:
    image: fluent/fluentd:${fluentd_image_tag:?}
    mem_limit: 256M
    environment:
      FLUENTD_TAG: ${FLUENTD_TAG:-sentry}
    volumes:
      - ${fluentd_data_path:?}/log:/fluentd/log
      - ${fluentd_data_path:?}/etc:/fluentd/etc
      - ${fluentd_data_path:?}/storage:/fluentd/storage
    ports:
      - "24224:24224"
      - "24224:24224/udp"

EOF
    echo "services/fluentd/24224" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
else
    echo "    - Manager not configured to run a fluentd logging service. Not adding fluentd container to stack."
fi

# Set the docker compose command
echo "  - Set compose command"
export docker_compose_cmd="${cmd_prefix:?} docker compose -f ./docker-compose.yml -f ./docker-compose.custom.yml"

# Modify consumer for snuba
if [ "${PATCH_SNUBA:-true}" = "true" ]; then
    echo "  - Replacing snuba 'rust-consumer' with 'consumer'"
    # REF: https://github.com/getsentry/snuba/issues/5707
    sed -ie "s/rust-consumer/consumer/g" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
    echo "snuba-patch - https://github.com/getsentry/snuba/issues/5707" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
fi

if ! cmp -s "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt" "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.txt"; then
    echo "  - A breaking change was made to the docker compose stack. Stopping it before continuing to avoid issues while applying updates."
    ${docker_compose_cmd:?} down --remove-orphans
    mv -fv "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt" "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.txt"
else
    echo "  - Sentry enhance-image.sh config file has not changed"
fi