#!/usr/bin/env bash
###
# File: 50-run-sentry-installation.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:34:52 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 15th December 2025 4:02:11 pm
# Modified By: Josh.5 (jsunnex@gmail.com)
###

# Check if we should perform a "nuclear clean" before running the installation
nuclear_clean_key_file="${SENTRY_DATA_PATH:?}/self_hosted/.z-nuclear-clean-key.txt"
exec_nuclear_clean_value="${EXEC_NUCLEAR_CLEAN:-false}"
if [ "${exec_nuclear_clean_value}" != "false" ]; then
    last_nuclear_clean_key=$(cat "${nuclear_clean_key_file}" 2>/dev/null || echo "")
    if [ "${exec_nuclear_clean_value}" != "${last_nuclear_clean_key}" ]; then
        echo "--- Running a nuclear clean of the Kafka volumes ---"
        ${docker_compose_cmd:?} down --volumes --remove-orphans
        ${docker_cmd:?} volume rm sentry-kafka || true
        rm -f ${SENTRY_DATA_PATH:?}/self_hosted/.z-installed-sentry-version.txt
        echo "${exec_nuclear_clean_value}" >"${nuclear_clean_key_file}"
    else
        echo "--- Skipping nuclear clean because the provided EXEC_NUCLEAR_CLEAN value matches the previous key '${last_nuclear_clean_key:-}'. ---"
    fi
fi

# Check that the self-hosted images exist. If they do not, we need to force a re-installation
if ! ${docker_cmd:?} images | grep -q 'sentry-self-hosted-local'; then
    echo "--- The sentry-self-hosted-local image does not exist, forcing a re-install ---"
    rm -f ${SENTRY_DATA_PATH:?}/self_hosted/.z-installed-sentry-version.txt
fi

echo "--- Sentry installation ---"
cd ${SENTRY_DATA_PATH:?}/self_hosted
export REPORT_SELF_HOSTED_ISSUES=0
if [ "$(cat ${SENTRY_DATA_PATH:?}/self_hosted/.z-installed-sentry-version.txt 2>/dev/null)" != "${SENTRY_VERSION}" ]; then
    echo "  - Running Sentry installation"
    ${install_cmd:?}
    echo "${SENTRY_VERSION}" >${SENTRY_DATA_PATH:?}/self_hosted/.z-installed-sentry-version.txt
elif [ "X${FORCE_RUN_INSTALL_SCRIPT:-}" != "X" ]; then
    echo "  - Running Sentry installation due to FORCE_RUN_INSTALL_SCRIPT"
    ${install_cmd:?}
    echo "${SENTRY_VERSION}" >${SENTRY_DATA_PATH:?}/self_hosted/.z-installed-sentry-version.txt
else
    echo "  - Skipping Sentry installation as the current installed version is what we are about to start and nothing has changed"
fi
echo

echo "--- Create Initial Admin User ---"
if [ "${SKIP_ADMIN_USER_CREATE:-}" = "true" ]; then
    echo "  - Container configured to skip admin user creation"
else
    if [ ! -f "${SENTRY_DATA_PATH:?}/self_hosted/.z-initial-admin-generated.txt" ]; then
        echo "  - Generating initial admin user credentials"
        temp_password=$(echo "$(date +%s.%N) $(shuf -n1 -i0-999999)" | sha256sum | base64 | head -c 16)
        cd ${SENTRY_DATA_PATH:?}/self_hosted
        ${docker_compose_cmd:?} run --rm web sentry createuser --email "${SENTRY_INITIAL_ADMIN_EMAIL:?}" --password "${temp_password:?}" --superuser || true
        echo "  - Created user ${SENTRY_INITIAL_ADMIN_EMAIL:?} with temporary password ${temp_password:?}"
        echo "${SENTRY_VERSION}" >${SENTRY_DATA_PATH:?}/self_hosted/.z-initial-admin-generated.txt
    else
        echo "  - The initial admin user was already created"
    fi
fi
echo
