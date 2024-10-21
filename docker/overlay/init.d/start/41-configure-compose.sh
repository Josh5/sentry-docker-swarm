#!/usr/bin/env bash
###
# File: 41-configure-compose.sh
# Project: start
# File Created: Monday, 21st October 2024 10:19:15 pm
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Tuesday, 22nd October 2024 1:00:34 am
# Modified By: Josh5 (jsunnex@gmail.com)
###


echo "--- Create custom docker-compose.custom.yml file ---"
echo "" >"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
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
    name: ${custom_docker_network_name}
    external: true

EOF

# Use env_file
echo "  - Configure all services to read .env.custom"
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-env-import: &env-import
  env_file: [.env.custom]

EOF

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
fi

# Memory limits
echo "  - Configure services memory limits"
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-mem-limits: &mem-limits
  mem_limit: ${DIND_MEMLIMIT:-0}

EOF

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
