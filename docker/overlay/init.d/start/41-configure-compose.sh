#!/usr/bin/env bash
###
# File: 41-configure-compose.sh
# Project: start
# File Created: Monday, 21st October 2024 10:19:15 pm
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 21st October 2024 11:24:40 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###


echo "--- Create custom docker-compose.custom.yml file ---"
echo "" >"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
compose_services="$(${docker_cmd:?} compose -f ./docker-compose.yml config --services)"

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
      fluentd-address: ${FLUENTD_ADDRESS:?}
      tag: ${FLUENTD_TAG:?}

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
