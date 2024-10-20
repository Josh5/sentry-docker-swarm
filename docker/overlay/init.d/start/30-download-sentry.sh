#!/usr/bin/env bash
###
# File: 30-download-sentry.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:14:56 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 21st October 2024 12:29:14 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

RESTORE_VOLUMES_SCRIPT=$(
    cat <<EOF
#!/bin/sh
set -e
cd "\$(dirname "\$0")"
echo "--- Restore Sentry Volumes ---"
volumes="sentry-data sentry-postgres sentry-redis sentry-zookeeper sentry-kafka sentry-clickhouse sentry-symbolicator"
for volume_name in \${volumes}; do
if [ -f "\$(pwd)/\${volume_name}.tar" ]; then
    echo "  - Deleting volume \${volume_name} if it exsits..."
    ${docker_cmd:?} volume rm \${volume_name} || true
    echo "  - Creating volume \${volume_name}..."
    ${docker_cmd:?} volume create --name=\${volume_name}
    echo "  - Restoring data into new volume \${volume_name}..."
    ${docker_cmd:?} run --rm -w /data -v "\${volume_name}":/data -v "\$(pwd)":/backup ubuntu tar --same-owner -xvf /backup/\${volume_name}.tar --strip 1
fi
done
EOF
)

echo "--- Downloading Sentry ---"
PREVIOUS_SENTRY_VERSION="$(cat "${SENTRY_DATA_PATH}"/self_hosted/.z-downloaded-sentry-version.txt 2>/dev/null || echo "UNKNOWN")"
echo "  - Previously installed version ${PREVIOUS_SENTRY_VERSION}"
if [ "${PREVIOUS_SENTRY_VERSION:-}" != "${SENTRY_VERSION}" ]; then
    echo "  - Downloading Sentry version ${SENTRY_VERSION:?}"
    date_string=$(date +"%Y-%m-%d-%H%M%S")
    cd /tmp
    wget -q "https://github.com/getsentry/self-hosted/archive/refs/tags/${SENTRY_VERSION:?}.tar.gz" \
        -O "/tmp/${SENTRY_VERSION:?}.tar.gz"
    tar xzf ${SENTRY_VERSION:?}.tar.gz

    echo "  - Backing up previous install to ${SENTRY_DATA_PATH}/update_backups/self_hosted-v${PREVIOUS_SENTRY_VERSION:-UNKNOWN}-${date_string}..."
    mkdir -p ${SENTRY_DATA_PATH}/update_backups
    mv -fv ${SENTRY_DATA_PATH}/self_hosted ${SENTRY_DATA_PATH}/update_backups/self_hosted-v${PREVIOUS_SENTRY_VERSION:-UNKNOWN}-${date_string}

    echo "  - Unpacking new Sentry files..."
    mv -v /tmp/self-hosted-${SENTRY_VERSION:?} ${SENTRY_DATA_PATH}/self_hosted
    echo "${SENTRY_VERSION}" >${SENTRY_DATA_PATH}/self_hosted/.z-downloaded-sentry-version.txt
    cd ${SENTRY_DATA_PATH}/self_hosted

    echo "  - Pulling down any existing Sentry stack services..."
    ${docker_cmd:?} compose down --remove-orphans

    echo "  - Backup Docker volumes..."
    volumes="sentry-data sentry-postgres sentry-redis sentry-zookeeper sentry-kafka sentry-clickhouse sentry-symbolicator"
    mkdir -p "${SENTRY_DATA_PATH}"/update_backups/self_hosted-v${PREVIOUS_SENTRY_VERSION:-UNKNOWN}-${date_string}/volumes
    for volume_name in ${volumes}; do
        if ${docker_cmd:?} volume inspect "${volume_name}" >/dev/null 2>&1; then
            echo "    - Backing up ${volume_name}..."
            ${docker_cmd:?} run --rm -v "${volume_name}":/data -v "${SENTRY_DATA_PATH}"/update_backups/self_hosted-v${PREVIOUS_SENTRY_VERSION:-UNKNOWN}-${date_string}/volumes:/backup ubuntu tar -zcvf /backup/${volume_name}.tar /data
        else
            echo "  Volume ${volume_name} not found, skipping backup."
        fi
    done

    echo "  - Install volumes restore script..."
    echo "${RESTORE_VOLUMES_SCRIPT:?}" >"${SENTRY_DATA_PATH}"/update_backups/self_hosted-v${PREVIOUS_SENTRY_VERSION:-UNKNOWN}-${date_string}/volumes/restore-volumes.sh
    chmod +x "${SENTRY_DATA_PATH}"/update_backups/self_hosted-v${PREVIOUS_SENTRY_VERSION:-UNKNOWN}-${date_string}/volumes/restore-volumes.sh

    echo "  - Cleaning out old docker images..."
    ${docker_cmd:?} image prune --all --force
else
    echo "  - The downloaded version of Sentry is already ${SENTRY_VERSION:?}"
fi

rm -f "${SENTRY_DATA_PATH}/self_hosted/.z-manager-service-running.txt"
echo
