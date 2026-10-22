#!/usr/bin/env bash
###
# File: 30-download-sentry.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:14:56 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Friday, 29th November 2024 1:00:03 am
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Downloading Sentry ---"
PREVIOUS_SENTRY_VERSION="$(cat "${SENTRY_DATA_PATH:?}/self_hosted/.z-downloaded-sentry-version.txt" 2>/dev/null || echo "UNKNOWN")"
echo "  - Previously installed version ${PREVIOUS_SENTRY_VERSION}"
if [ "${PREVIOUS_SENTRY_VERSION}" != "${SENTRY_VERSION:?}" ]; then
    date_string=$(date +"%Y-%m-%d-%H%M%S")
    backup_path="${SENTRY_DATA_PATH}/update_backups/self_hosted-v${PREVIOUS_SENTRY_VERSION}-${date_string}"
    echo "  - Downloading Sentry version ${SENTRY_VERSION}"
    if ! wget -q "https://github.com/getsentry/self-hosted/archive/refs/tags/${SENTRY_VERSION}.tar.gz" \
        -O "/tmp/${SENTRY_VERSION}.tar.gz"; then
        echo "    - Failed to download Sentry version ${SENTRY_VERSION}. The version may not exist." >&2
        exit 1
    fi
    tar xzf "/tmp/${SENTRY_VERSION}.tar.gz" -C /tmp

    # Stop the OLD Compose project before moving its configuration or reading data.
    # Removed services and custom sidecars must also be stopped for a consistent backup.
    previous_compose_files=(-f ./docker-compose.yml)
    if [ -f "${SENTRY_DATA_PATH}/self_hosted/docker-compose.custom.yml" ]; then
        previous_compose_files+=(-f ./docker-compose.custom.yml)
    fi
    if [ -f "${SENTRY_DATA_PATH}/self_hosted/.env.custom" ]; then
        previous_compose_files+=(--env-file .env.custom)
    fi
    backup_volumes="sentry-data sentry-postgres sentry-redis sentry-zookeeper sentry-kafka sentry-clickhouse sentry-symbolicator sentry-seaweedfs sentry-vroom sentry-taskbroker"
    if [ -f "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml" ]; then
        if [ "${BACKUP_VOLUMES_ON_UPDATE:-}" = "true" ]; then
            previous_compose_json=$(${docker_compose_cmd:?} "${previous_compose_files[@]}" --profile '*' config --format json)
            # Compose supplies the actual names, including project-prefixed and custom volumes.
            backup_volumes=$(yq -p=json -er '[.volumes[]?.name] | unique | join(" ")' <<<"${previous_compose_json}")
            unset previous_compose_json
        fi
        echo "  - Stopping the previous Sentry stack..."
        ${docker_compose_cmd:?} "${previous_compose_files[@]}" --profile '*' down --remove-orphans
    fi

    if [ "${BACKUP_VOLUMES_ON_UPDATE:-}" = "true" ]; then
        # Keep the old installation in place if any archive fails. A retry must not
        # mistake a partially downloaded new release for a completed backup.
        volumes_backup_path="${backup_path}.volumes"
        mkdir -p "${volumes_backup_path}"
        for volume_name in ${backup_volumes}; do
            if ${docker_cmd:?} volume inspect "${volume_name}" >/dev/null 2>&1; then
                echo "    - Backing up ${volume_name}..."
                ${docker_cmd:?} run --rm -v "${volume_name}:/data:ro" -v "${volumes_backup_path}:/backup" \
                    ubuntu tar -zcpf "/backup/${volume_name}.tar" -C /data .
            else
                echo "    - Volume ${volume_name} not found, skipping backup."
            fi
        done

        restore_script="${volumes_backup_path}/restore-volumes.sh"
        cp -f "$(dirname "${BASH_SOURCE[0]}")/../../defaults/helpers/restore-volumes.sh" "${restore_script}"
        read -r -a restore_docker_command <<<"${docker_cmd:?}"
        printf -v restore_docker_command_quoted '%q ' "${restore_docker_command[@]}"
        restore_docker_command_replacement=$(printf '%s' "${restore_docker_command_quoted}" | sed 's/[\\&|]/\\&/g')
        sed -i "s|@DOCKER_COMMAND@|${restore_docker_command_replacement}|g" "${restore_script}"
        chmod +x "${volumes_backup_path}/restore-volumes.sh"
    fi

    echo "  - Backing up previous install to ${backup_path}..."
    mkdir -p "${SENTRY_DATA_PATH}/update_backups"
    mv -v "${SENTRY_DATA_PATH}/self_hosted" "${backup_path}"
    if [ "${BACKUP_VOLUMES_ON_UPDATE:-}" = "true" ]; then
        mv -v "${volumes_backup_path}" "${backup_path}/volumes"
    fi
    echo "  - Unpacking new Sentry files..."
    mv -v "/tmp/self-hosted-${SENTRY_VERSION}" "${SENTRY_DATA_PATH}/self_hosted"
    echo "${SENTRY_VERSION}" >"${SENTRY_DATA_PATH}/self_hosted/.z-downloaded-sentry-version.txt"
    cd "${SENTRY_DATA_PATH}/self_hosted" || exit 1
else
    echo "  - The downloaded version of Sentry is already ${SENTRY_VERSION}"
fi

rm -f "${SENTRY_DATA_PATH}/self_hosted/.z-manager-service-running.txt"
echo
