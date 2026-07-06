#!/usr/bin/env bash
###
# File: 45-configure-compose.sh
# Project: start
# File Created: Monday, 21st October 2024 10:19:15 pm
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Friday, 3rd July 2026 12:51:18 pm
# Modified By: Josh.5 (jsunnex@gmail.com)
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
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-logging-json: &logging-json
  logging:
    driver: json-file
    options:
      max-size: 10m
      max-file: 5

EOF
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
      fluentd-address: "localhost:24224"
      tag: "sentry"
      fluentd-request-ack: "true"
      fluentd-async: "true"
      fluentd-async-reconnect-interval: "5s"
      fluentd-retry-wait: 5s
      labels: "source.service,source.version"

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

x-mem-limits-redis: &mem-limits-redis
  mem_limit: ${REDIS_MEMLIMIT:-0}

EOF
echo "x-mem-limits/mem_limit/${DIND_MEMLIMIT:-0}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
echo "x-mem-limits-redis/mem_limit/${REDIS_MEMLIMIT:-0}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"

# CPU limits
echo "  - Calculate stack CPU limits..."
TOTAL_CPUS=$(nproc)
STACK_CPU_PERCENT=$(echo "${DIND_CPU_PERCENT:-75} * 0.8" | bc)
STACK_CPU_PERCENT=${STACK_CPU_PERCENT%.*}
echo "    - Calculating backend services CPU Quota from ${STACK_CPU_PERCENT:?}% of a total ${TOTAL_CPUS:?} CPUs"
CPU_PERIOD=100000
SERVICES_CPU_QUOTA=$(echo "${CPU_PERIOD:?} * $(nproc) * 0.${STACK_CPU_PERCENT:?}" | bc)
SERVICES_CPU_QUOTA=${SERVICES_CPU_QUOTA%.*}
echo "    - CPU Quota: ${SERVICES_CPU_QUOTA:?}/${CPU_PERIOD:?}"
echo "  - Configure docker stack CPU cgroup"
${cmd_prefix:?} cgcreate -g cpu:/sentry-backend-services
echo "  - Apply CPU Share limits ${DIND_CPU_SHARES:-512}"
${cmd_prefix:?} cgset -r cpu.weight="${DIND_CPU_SHARES:-512}" /sentry-backend-services
echo "  - Apply CPU Max quota as ${SERVICES_CPU_QUOTA:?} ${CPU_PERIOD:?}"
${cmd_prefix:?} cgset -r cpu.max="${SERVICES_CPU_QUOTA:?} ${CPU_PERIOD:?}" /sentry-backend-services
echo "  - Configure services cgroup_parent as /sentry-backend-services in docker-compose.custom.yml"
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
x-backend-services-cpu-limits: &backend-services-cpu-limits
  cgroup_parent: /sentry-backend-services

x-cpu-shares-web: &cpu-shares-web
  cpu_shares: 2048

EOF
echo "x-backend-services-cpu-limits/cpus/${SERVICES_CPU_QUOTA:?}-${CPU_PERIOD:?}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
echo "x-cpu-limits/cpu_shares/${DIND_CPU_SHARES:-512}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"

# Consolidate
echo "  - Write custom config to all services"
echo "services:" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
for service in ${compose_services:?}; do
    echo "    - Applying to service '${service:?}'."
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
  ${service:?}:
    labels:
      - "source.service=${service:?}"
      - "source.version=Sentry-v${SENTRY_VERSION:?}"
    <<: 
      - *env-import
EOF
    # Apply custom logging driver to some services
    if [[ "${service:?}" == "nginx" ]]; then
        echo "      - *logging-json" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
    else
        echo "      - *logging-base" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
    fi
    # Apply memory limits. Some services have custom memory limits
    if [[ "${service:?}" == "redis" ]]; then
        echo "      - *mem-limits-redis" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
    else
        echo "      - *mem-limits" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
    fi
    # Check if the service name is either the web, nginx or relay. Give these a higher cpu share.
    # For all other services, limit them to whatever is configured with the /sentry-backend-services cgroup.
    if [[ "${service:?}" == "web" || "${service:?}" == "nginx" || "${service:?}" == "relay" ]]; then
        echo "      - *cpu-shares-web" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
    else
        echo "      - *backend-services-cpu-limits" >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"
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

# Configure ingest-filter service
echo "  - Configure sentry-ingest-filter proxy service"
if [ "${SENTRY_INGEST_FILTER_ENABLED:-false}" = "true" ]; then
    echo "    - Adding custom sentry-ingest-filter container to services."
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml"

  sentry-ingest-filter:
    image: docker.io/josh5/sentry-ingest-filter:latest
    mem_limit: 512M
    environment:
      - LISTEN_ADDR=:8081
      - RELAY_UPSTREAM_URL=http://relay:3000
      - FILTER_MODE_EVENT=${SENTRY_INGEST_FILTER_MODE_EVENT:-observe}
      - FILTER_MODE_TRANSACTION=${SENTRY_INGEST_FILTER_MODE_TRANSACTION:-observe}
      - FILTER_MODE_PROFILE=${SENTRY_INGEST_FILTER_MODE_PROFILE:-observe}
      - FILTER_MODE_CHECKIN=${SENTRY_INGEST_FILTER_MODE_CHECKIN:-observe}
      - FILTER_MODE_LOG=${SENTRY_INGEST_FILTER_MODE_LOG:-observe}
      - WINDOW_MINUTES=${SENTRY_INGEST_FILTER_WINDOW_MINUTES:-7}
      - MAX_ITEMS_PER_SIGNATURE_EVENT=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_EVENT:-250}
      - MAX_ITEMS_PER_SIGNATURE_TRANSACTION=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_TRANSACTION:-250}
      - MAX_ITEMS_PER_SIGNATURE_PROFILE=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_PROFILE:-250}
      - MAX_ITEMS_PER_SIGNATURE_CHECKIN=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_CHECKIN:-250}
      - MAX_ITEMS_PER_SIGNATURE_LOG=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_LOG:-250}
      - SAMPLE_RATE_AFTER_LIMIT=${SENTRY_INGEST_FILTER_SAMPLE_RATE_AFTER_LIMIT:-0.01}
      - INCLUDE_ENVIRONMENT=${SENTRY_INGEST_FILTER_INCLUDE_ENVIRONMENT:-true}
      - INCLUDE_RELEASE=${SENTRY_INGEST_FILTER_INCLUDE_RELEASE:-false}
      - TRIM_MAX_BREADCRUMBS=${SENTRY_INGEST_FILTER_TRIM_MAX_BREADCRUMBS:-5}
      - SNAPSHOT_PATH=/data/sentry-ingest-filter-snapshot.json
      - SNAPSHOT_INTERVAL=${SENTRY_INGEST_FILTER_SNAPSHOT_INTERVAL:-1m}
      - METRIC_LOG_INTERVAL=${SENTRY_INGEST_FILTER_METRIC_LOG_INTERVAL:-1m}
      - BUFFER_ENABLED=${SENTRY_INGEST_FILTER_BUFFER_ENABLED:-false}
      - BUFFER_DIR=/data/sentry-ingest-filter-buffer
      - BUFFER_MAX_BYTES=${SENTRY_INGEST_FILTER_BUFFER_MAX_BYTES:-1073741824}
      - RETRY_INITIAL_BACKOFF=${SENTRY_INGEST_FILTER_RETRY_INITIAL_BACKOFF:-5s}
      - RETRY_MAX_BACKOFF=${SENTRY_INGEST_FILTER_RETRY_MAX_BACKOFF:-2m}
      - RETRY_SWEEP_INTERVAL=${SENTRY_INGEST_FILTER_RETRY_SWEEP_INTERVAL:-5s}
      - LOG_DECISIONS=${SENTRY_INGEST_FILTER_LOG_DECISIONS:-false}
      - DEBUG=${SENTRY_INGEST_FILTER_DEBUG:-false}
    volumes:
      - ${SENTRY_DATA_PATH}/sentry-ingest-filter:/data
    ports:
      - "8081:8081"

EOF
    echo "services/sentry-ingest-filter/8081" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"

    # Track non-structural env variables in a separate file to avoid full stack tear-downs
    echo "" >"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MODE_EVENT=${SENTRY_INGEST_FILTER_MODE_EVENT:-observe}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MODE_TRANSACTION=${SENTRY_INGEST_FILTER_MODE_TRANSACTION:-observe}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MODE_PROFILE=${SENTRY_INGEST_FILTER_MODE_PROFILE:-observe}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MODE_CHECKIN=${SENTRY_INGEST_FILTER_MODE_CHECKIN:-observe}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MODE_LOG=${SENTRY_INGEST_FILTER_MODE_LOG:-observe}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "WINDOW_MINUTES=${SENTRY_INGEST_FILTER_WINDOW_MINUTES:-7}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MAX_ITEMS_PER_SIGNATURE_EVENT=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_EVENT:-250}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MAX_ITEMS_PER_SIGNATURE_TRANSACTION=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_TRANSACTION:-250}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MAX_ITEMS_PER_SIGNATURE_PROFILE=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_PROFILE:-250}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MAX_ITEMS_PER_SIGNATURE_CHECKIN=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_CHECKIN:-250}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "MAX_ITEMS_PER_SIGNATURE_LOG=${SENTRY_INGEST_FILTER_MAX_ITEMS_PER_SIGNATURE_LOG:-250}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "SAMPLE_RATE_AFTER_LIMIT=${SENTRY_INGEST_FILTER_SAMPLE_RATE_AFTER_LIMIT:-0.01}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "INCLUDE_ENVIRONMENT=${SENTRY_INGEST_FILTER_INCLUDE_ENVIRONMENT:-true}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "INCLUDE_RELEASE=${SENTRY_INGEST_FILTER_INCLUDE_RELEASE:-false}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "TRIM_MAX_BREADCRUMBS=${SENTRY_INGEST_FILTER_TRIM_MAX_BREADCRUMBS:-5}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "SNAPSHOT_INTERVAL=${SENTRY_INGEST_FILTER_SNAPSHOT_INTERVAL:-1m}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "METRIC_LOG_INTERVAL=${SENTRY_INGEST_FILTER_METRIC_LOG_INTERVAL:-1m}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "BUFFER_ENABLED=${SENTRY_INGEST_FILTER_BUFFER_ENABLED:-false}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "BUFFER_MAX_BYTES=${SENTRY_INGEST_FILTER_BUFFER_MAX_BYTES:-1073741824}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "RETRY_INITIAL_BACKOFF=${SENTRY_INGEST_FILTER_RETRY_INITIAL_BACKOFF:-5s}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "RETRY_MAX_BACKOFF=${SENTRY_INGEST_FILTER_RETRY_MAX_BACKOFF:-2m}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "RETRY_SWEEP_INTERVAL=${SENTRY_INGEST_FILTER_RETRY_SWEEP_INTERVAL:-5s}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "LOG_DECISIONS=${SENTRY_INGEST_FILTER_LOG_DECISIONS:-false}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
    echo "DEBUG=${SENTRY_INGEST_FILTER_DEBUG:-false}" >>"${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt"
else
    echo "    - Manager not configured to run a sentry-ingest-filter proxy service. Not adding sentry-ingest-filter container to stack."
fi

# Patch Sentry nginx.conf file
echo "  - Configure sentry-ingest-filter routing in Sentry nginx.conf"
if [ -f "${SENTRY_DATA_PATH}/self_hosted/nginx.conf" ]; then
    nginx_conf_file="${SENTRY_DATA_PATH}/self_hosted/nginx.conf"
elif [ -f "${SENTRY_DATA_PATH}/self_hosted/nginx/nginx.conf" ]; then
    nginx_conf_file="${SENTRY_DATA_PATH}/self_hosted/nginx/nginx.conf"
else
    nginx_conf_file=""
fi

if [ -n "${nginx_conf_file}" ]; then
    echo "    - Found Sentry nginx.conf at: ${nginx_conf_file}"
    if [ ! -f "${nginx_conf_file}.bak" ]; then
        echo "    - Creating backup of original nginx.conf"
        cp -f "${nginx_conf_file}" "${nginx_conf_file}.bak"
    fi
    # Restore clean state from backup
    cp -f "${nginx_conf_file}.bak" "${nginx_conf_file}"

    if [ "${SENTRY_INGEST_FILTER_ENABLED:-false}" = "true" ]; then
        echo "    - Patching nginx.conf for sentry-ingest-filter routing..."
        sed -i "s|upstream relay {|upstream ingest-filter {\n\t\tserver sentry-ingest-filter:8081;\n\t\tkeepalive 2;\n\t}\n\n\tupstream relay {|" "${nginx_conf_file}"
        sed -i '/location \/api\/store\/ {/,/}/ s|http://relay|http://ingest-filter|' "${nginx_conf_file}"
        sed -i "s|location ~ \^/api/\[1-9\]|location ~ ^/api/[1-9]\\\\d*/(store\|envelope)/ {\n\t\t\tproxy_pass http://ingest-filter;\n\t\t}\n\n\t\tlocation ~ ^/api/[1-9]|" "${nginx_conf_file}"
    else
        echo "    - Ingest filter disabled. Routing all relay traffic directly to relay container."
    fi
else
    echo "    - Warning: Sentry nginx.conf file not found, skipping routing patch."
fi

# Set the docker compose command
echo "  - Set compose command"
export docker_compose_cmd="${cmd_prefix:?} docker compose -f ./docker-compose.yml -f ./docker-compose.custom.yml"

########### START docker-compose.yml PATCHES ###########
#   ____       _       _        ____                                        ____             __ _
#  |  _ \ __ _| |_ ___| |__    / ___|___  _ __ ___  _ __   ___  ___  ___   / ___|___  _ __  / _(_) __ _
#  | |_) / _` | __/ __| '_ \  | |   / _ \| '_ ` _ \| '_ \ / _ \/ __|/ _ \ | |   / _ \| '_ \| |_| |/ _` |
#  |  __/ (_| | || (__| | | | | |__| (_) | | | | | | |_) | (_) \__ \  __/ | |__| (_) | | | |  _| | (_| |
#  |_|   \__,_|\__\___|_| |_|  \____\___/|_| |_| |_| .__/ \___/|___/\___|  \____\___/|_| |_|_| |_|\__, |
#                                                  |_|                                            |___/
#

# Modify consumer for snuba for affected versions (< 25.9.0)
#   Refs:
#   - https://github.com/getsentry/snuba/issues/5707
snuba_patch_cutoff_version="25.9.0"
if [ "$(printf '%s\n' "${SENTRY_VERSION:?}" "${snuba_patch_cutoff_version}" | sort -V | head -n1)" = "${SENTRY_VERSION:?}" ] && [ "${SENTRY_VERSION:?}" != "${snuba_patch_cutoff_version}" ]; then
    echo "  - Replacing snuba 'rust-consumer' with 'consumer'"
    sed -i "s/rust-consumer/consumer/g" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
    echo "snuba-patch - https://github.com/getsentry/snuba/issues/5707" >>"${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt"
fi

########### END docker-compose.yml PATCHES ###########

config_changed="false"

if [ ! -f "${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt" ]; then
    config_changed="true"
fi

if ! cmp -s "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt" "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.txt"; then
    echo "  - A breaking change was made to the docker compose stack. Stopping it before continuing to avoid issues while applying updates."
    ${docker_compose_cmd:?} down --remove-orphans
    mv -fv "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.tmp.txt" "${SENTRY_DATA_PATH}/self_hosted/.z-custom-compose-config.txt"
    config_changed="true"
else
    echo "  - Sentry enhance-image.sh config file has not changed"
fi

# Check if only the ingest-filter environment variables changed (non-breaking update)
if [ "${SENTRY_INGEST_FILTER_ENABLED:-false}" = "true" ]; then
    if [ ! -f "${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.txt" ]; then
        mv -fv "${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt" "${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.txt"
        config_changed="true"
    elif ! cmp -s "${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt" "${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.txt"; then
        echo "  - Ingest filter configuration has been modified."
        mv -fv "${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.tmp.txt" "${SENTRY_DATA_PATH}/self_hosted/.z-ingest-filter-config.txt"
        config_changed="true"
    fi
fi

if [ "${SENTRY_INGEST_FILTER_ENABLED:-false}" = "true" ] && [ "${config_changed}" = "true" ]; then
    echo "  - Sentry configuration or ingest filter configuration has changed. Pulling latest sentry-ingest-filter image..."
    ${docker_cmd:?} pull docker.io/josh5/sentry-ingest-filter:latest || true
fi
