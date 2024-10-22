#!/usr/bin/env bash
###
# File: 41-configure-compose.sh
# Project: start
# File Created: Monday, 21st October 2024 10:19:15 pm
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Tuesday, 22nd October 2024 3:29:04 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###


echo "--- Create custom docker-compose.custom.yml file ---"
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
    echo "      - Configure Docker Compose to use json-file log driver for all services."
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
    echo "      - Configure Docker Compose to use fluentd log driver for all services."
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
    echo "      - Configure Docker Compose to use local log driver for all services."
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
echo "  - Configure services memory limits"
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-mem-limits: &mem-limits
  mem_limit: ${DIND_MEMLIMIT:-0}

EOF
echo "x-mem-limits/mem_limit/${DIND_MEMLIMIT:-0}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"

# Consolidate
echo "  - Write custom config to all services"
echo "services:" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
for service in ${compose_services:?}; do
    echo "      - Applying to service '${service:?}'."
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
  ${service:?}:
    <<: 
      - *env-import
      - *logging-base
      - *mem-limits
EOF
done
echo "  - Set compose command"
export docker_compose_cmd="${cmd_prefix:?} docker compose -f ./docker-compose.yml -f ./docker-compose.custom.yml"


if ! cmp -s "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt" "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.txt"; then
    echo "  - A breaking change was made to the docker compose stack. Stopping it before continuing to avoid issues while applying updates."
    ${docker_compose_cmd:?} down --remove-orphans
    mv -fv "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt" "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.txt"
else
    echo "  - Sentry enhance-image.sh config file has not changed"
fi
