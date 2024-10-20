#!/usr/bin/env sh
###
# File: entrypoint.sh
# Project: overlay
# File Created: Friday, 18th October 2024 5:05:51 pm
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Friday, 18th October 2024 5:19:34 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###
set -eu

echo "--- Reading config ---"
docker_version=$(docker --version | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
dind_continer_name="sentry-swarm-dind"
dind_bridge_network_name="sentry-swarm-dind-net"
dind_cache_path="${SENTRY_DATA_PATH}/docker-cache"
dind_run_path="${SENTRY_DATA_PATH}/docker-sock"
cmd_prefix=""
docker_cmd="docker"
install_cmd="./install.sh --skip-user-creation --no-report-self-hosted-issues"
echo

echo "--- Configure TERM monitor ---"
_term() {
if [ "${KEEP_ALIVE}" = "false" ]; then
    echo "--- Sending signal for supervised stack to stop ---"
    mkdir -p ${SENTRY_DATA_PATH}/self_hosted
    rm -f "${SENTRY_DATA_PATH}/self_hosted/.z-manager-service-running.txt"
    docker stop sentry-stack-term-signal &> /dev/null || true
    if [ "${RUN_WITH_DIND:-}" = "true" ]; then
    docker stop --time 120 ${dind_continer_name} &> /dev/null || true
    docker network rm "${dind_bridge_network_name}" &> /dev/null || true
    else
    docker run -d --rm \
        --name sentry-stack-term-signal \
        --volume /var/run/docker.sock:/var/run/docker.sock \
        --volume ${SENTRY_DATA_PATH}/self_hosted:${SENTRY_DATA_PATH}/self_hosted \
        --workdir ${SENTRY_DATA_PATH}/self_hosted \
        --entrypoint="" \
        docker:${docker_version} \
        docker compose down --remove-orphans
    fi
    echo
fi
exit 0
}
docker stop sentry-stack-term-signal &> /dev/null || true
trap _term SIGTERM SIGINT
echo

echo "--- Create data directories ---"
mkdir -p \
${SENTRY_DATA_PATH}/self_hosted \
${SENTRY_DATA_PATH}/update_backups
echo

echo "--- Ensure Sentry network exists and update compose stack to use it ---"
sentry_net_name=$(docker network ls --filter name=${NETWORK_NAME:?} --format "{{.Name}}" || echo "")
if [ "X${sentry_net_name:-}" = "X" ]; then
echo "  - Failed to discover the sentry private network. Exit!"
exit 1
fi
echo "  - Private network discovered with name ${sentry_net_name}"
echo

echo "--- Configure DIND ---"
if [ "${RUN_WITH_DIND:-}" = "true" ]; then
echo "  - Ensure DIND network exists..."
existing_network=$(docker network ls 2> /dev/null | grep "${dind_bridge_network_name}" || echo "")
if [ "X${existing_network}" = "X" ]; then
    echo "    - Creating private network for DIND container..."
    docker network create -d bridge "${dind_bridge_network_name}"
else
    echo "    - A private network for DIND named ${dind_bridge_network_name} already exists!"
fi
echo

echo "  - Configure DIND container run aliases..."
mkdir -p ${dind_cache_path}
mkdir -p ${dind_run_path}
DIND_RUN_CMD="docker run --privileged -d --rm --name ${dind_continer_name} \
    --memory ${DIND_MEMLIMIT:-0} \
    --env DOCKER_DRIVER=overlay2 \
    --volume ${dind_cache_path}:/var/lib/docker \
    --volume ${dind_run_path}:/var/run \
    --volume ${SENTRY_DATA_PATH}:${SENTRY_DATA_PATH} \
    --network ${dind_bridge_network_name} \
    --network-alias ${dind_continer_name} \
    --publish 9000:9000 \
    docker:${docker_version}-dind"
DIND_NET_CONN_CMD="docker network connect --alias ${dind_continer_name} ${sentry_net_name:?} ${dind_continer_name:?}"

echo "  - Writing DIND container config to env file"
echo "" > ${dind_cache_path}/new-dind-run-config.env
echo "docker_version=${docker_version:?}" >> ${dind_cache_path}/new-dind-run-config.env
echo "DIND_RUN_CMD=${DIND_RUN_CMD:?}" >> ${dind_cache_path}/new-dind-run-config.env
echo "DIND_NET_CONN_CMD=${DIND_NET_CONN_CMD:?}" >> ${dind_cache_path}/new-dind-run-config.env
#cat ${dind_cache_path}/new-dind-run-config.env

echo "  - Checking if config has changed since last run"
if ! cmp -s "${dind_cache_path}/new-dind-run-config.env" "${dind_cache_path}/current-dind-run-config.env"; then
    echo "    - Env has changed. Stopping up old dind container due to possible config update"
    docker stop --time 120 ${dind_continer_name} &> /dev/null || true
    docker rm ${dind_continer_name} &> /dev/null || true
    mv -fv "${dind_cache_path}/new-dind-run-config.env" "${dind_cache_path}/current-dind-run-config.env"
else
    echo "    - Env has not changed."
fi

echo "  - Ensure DIND container is running"
if ! docker ps | grep -q ${dind_continer_name}; then
    echo "    - Fetching latest docker in docker image 'docker:${docker_version}-dind' ---"
    docker pull docker:${docker_version}-dind
    echo

    echo "    - Creating DIND container ---"
    rm -rf ${dind_run_path}/*
    ${DIND_RUN_CMD:?}
    sleep 10
    echo
else
    echo "    - DIND container already running ---"
fi

echo "  - Configure DIND docker compose command..."
cmd_prefix="docker exec --workdir=${SENTRY_DATA_PATH}/self_hosted ${dind_continer_name}"
docker_cmd="${cmd_prefix} docker"
install_cmd="${cmd_prefix} ./install.sh --skip-user-creation --no-report-self-hosted-issues"
else
echo "  - Service configured to run on host docker socket. No DIND container required."
fi

echo "--- Installing dependencies ---"
if [ "${RUN_WITH_DIND:-}" = "true" ]; then
echo "  - Install bash and coreutils packages in DIND container required for install script"
${cmd_prefix} sh -c "apk add bash coreutils"
else
echo "  - Install bash and coreutils packages required for install script"
apk add bash coreutils
fi
echo "  - Install yq tool to endit Sentry config.yml"
wget -q "https://github.com/mikefarah/yq/releases/download/v4.43.1/yq_linux_amd64" \
    -O "/usr/bin/yq"
chmod +x "/usr/bin/yq"
echo

echo "--- Downloading Sentry ---"
PREVIOUS_SENTRY_VERSION="$(cat "${SENTRY_DATA_PATH}"/self_hosted/.z-downloaded-sentry-version.txt 2> /dev/null || echo "UNKNOWN")"
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
echo "${SENTRY_VERSION}" > ${SENTRY_DATA_PATH}/self_hosted/.z-downloaded-sentry-version.txt
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
cat << EOF > "${SENTRY_DATA_PATH}"/update_backups/self_hosted-v${PREVIOUS_SENTRY_VERSION:-UNKNOWN}-${date_string}/volumes/restore-volumes.sh
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
chmod +x "${SENTRY_DATA_PATH}"/update_backups/self_hosted-v${PREVIOUS_SENTRY_VERSION:-UNKNOWN}-${date_string}/volumes/restore-volumes.sh
if [ "${RUN_WITH_DIND:-}" = "true" ]; then
    echo "  - Cleaning out old docker images..."
    ${docker_cmd:?} image prune --all --force
fi
else
echo "  - The downloaded version of Sentry is already ${SENTRY_VERSION:?}"
fi
rm -f "${SENTRY_DATA_PATH}/self_hosted/.z-manager-service-running.txt"
echo

echo "--- Patch Docker Compose file ---"
if [ ! -f "${SENTRY_DATA_PATH}/self_hosted/docker-compose.original.yml" ]; then
cp -fv "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.original.yml"
fi
cp -fv "${SENTRY_DATA_PATH}/self_hosted/docker-compose.original.yml" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
if [ "${RUN_WITH_DIND:-}" != "true" ]; then
echo "  - Patch Docker Compose file memory limits."
sed -i "/x-restart-policy: &restart_policy/a \ \ mem_limit: ${DIND_MEMLIMIT:-0}" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
echo "  - Patch Docker Compose file with Swarm network."
echo "# Use a custom external network as the stacks default nework" >> "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
echo "networks:" >> "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
echo "  default:" >> "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
echo "    name: ${sentry_net_name}" >> "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
echo "    external: true" >> "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
cat "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
else
echo "  - Patch Docker Compose file memory limits within the DIND container."
sed -i "/x-restart-policy: &restart_policy/a \ \ mem_limit: ${DIND_MEMLIMIT:-0}" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
fi

echo "--- Configure Sentry ---"

########### START .env ###########
echo "  - Generate .env.custom"
cp -fv "${SENTRY_DATA_PATH}"/self_hosted/.env "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
echo "  - Adding additional config to .env"
echo -e "${SENTRY_ENV_CUSTOM:-}" >> "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
echo "  - Adding additional config to .env"
echo "  - Patch Docker Compose file to read .env.custom on all services."
sed -i "/x-restart-policy: &restart_policy/a \ \ env_file: [.env.custom]" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
########### END .env ###########

########### START sentry.conf.py ###########
echo "  - Generate sentry.conf.tmp.py"
cp -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.example.py" "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
# Import Bool
sed -i "/from sentry\.conf\.server import \*/a from sentry.utils.types import Bool" "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
cat << EOF >> "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"

####################
# CUSTOM OVERRIDES #
####################

EOF
echo "  - Disable Sentry beacon"
if [ "${SENTRY_BEACON_DISABLED:-}" = "true" ]; then
cat << EOF >> "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
# Disable the stats telemetry beacon for self-hosted installations
SENTRY_BEACON=False
EOF
else
echo "  - Keeping Sentry beacon default config"
fi
if [ "${SENTRY_CUSTOM_DB_CONFIG:-}" = "true" ]; then
echo "  - Configure custom DB connection details"
cat << EOF >> "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
DATABASES = {
    "default": {
        "ENGINE": "sentry.db.postgres",
        "NAME": "${SENTRY_DB_NAME:-postgres}",
        "USER": "${SENTRY_DB_USER:-postgres}",
        "PASSWORD": "${SENTRY_DB_PASSWORD:-}",
        "HOST": "${SENTRY_POSTGRES_HOST:-postgres}",
        "PORT": "${SENTRY_POSTGRES_PORT:-}",
    }
}
EOF
else
echo "  - Keeping Sentry DB default config"
fi
echo "  - Configure data retention to ${SENTRY_EVENT_RETENTION_DAYS:?} days"
sed -i "s|^SENTRY_EVENT_RETENTION_DAYS=.*|SENTRY_EVENT_RETENTION_DAYS=${SENTRY_EVENT_RETENTION_DAYS:?}|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
echo "  - Configure Sentry feature set to the ${SENTRY_COMPOSE_PROFILES:?} profile"
sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${SENTRY_COMPOSE_PROFILES:?}|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
echo "  - Configure SSL proxy X-Forwarded-Proto header"
cat << EOF >> "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SOCIAL_AUTH_REDIRECT_IS_HTTPS = True
EOF
echo -e "${SENTRY_CONF_CUSTOM:-}" >> "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
########### END sentry.conf.py ###########

########### START config.yml ###########
echo "  - Generate config.tmp.yml"
cp -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/config.example.yml" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i "... comments=\"\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
# Configure secret key
echo "  - Configure secret key"
yq eval -i ".\"system.secret-key\" = \"${SENTRY_SECRET_KEY:-supersecretkey}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
# Configure URL prefix
echo "  - Configure URL prefix"
yq eval -i ".\"system.url-prefix\" = \"${SENTRY_URL_PREFIX:-http://web:9000}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
# Configure Mail
echo "  - Configure mail details"
yq eval -i ".\"mail.from\" = \"${SENTRY_SERVER_EMAIL:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
if [ "${SENTRY_CUSTOM_MAIL_SERVER_CONFIG:-}" = "true" ]; then
echo "  - Configure custom smtp mail server"
sed -i "s|^SENTRY_MAIL_HOST=.*|# SENTRY_MAIL_HOST=example.com|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
yq eval -i ".\"mail.backend\" = \"smtp\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i ".\"mail.host\" = \"${SENTRY_EMAIL_HOST:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i ".\"mail.port\" = ${SENTRY_EMAIL_PORT:?}" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i ".\"mail.username\" = \"${SENTRY_EMAIL_USER:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i ".\"mail.password\" = \"${SENTRY_EMAIL_PASSWORD:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i ".\"mail.use-tls\" = ${SENTRY_EMAIL_USE_TLS:?}" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i ".\"mail.use-ssl\" = ${SENTRY_EMAIL_USE_SSL:?}" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
else
echo "  - Keeping Sentry mail default config"
echo "  - Configure Sentry mail host to ${SENTRY_MAIL_HOST:?}"
sed -i "s|^# SENTRY_MAIL_HOST=.*|SENTRY_MAIL_HOST=${SENTRY_MAIL_HOST:?}|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
sed -i "s|^SENTRY_MAIL_HOST=.*|SENTRY_MAIL_HOST=${SENTRY_MAIL_HOST:?}|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
fi
# Configure Filestore
if [ "X${SENTRY_FILESTORE_BACKEND_S3_BUCKET:-}" != "X" ]; then
echo "  - Configure custom Sentry S3 filestore backend"
yq eval -i ".\"filestore.backend\" = \"s3\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i ".\"filestore.options\".bucket_name = \"${SENTRY_FILESTORE_BACKEND_S3_BUCKET:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i ".\"filestore.options\".default_acl = \"private\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
else
echo "  - Keeping Sentry filestore backend default config"
fi
########### END config.yml ###########

########### START enhance-image.sh ###########
echo "  - Generate enhance-image.sh"
cp -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.example.sh" "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh"
chmod +x "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh"
if [ "X${ADDITIONAL_APT_PACKAGES:-}" != "X" ]; then
echo "  - Adding additional APT packages to be installed - ${ADDITIONAL_APT_PACKAGES:-}"
echo "apt-get update && apt-get install -y ${ADDITIONAL_APT_PACKAGES:-}" >> "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh"
fi
if [ "X${ADDITIONAL_PYTHON_MODULES:-}" != "X" ]; then
echo "  - Adding additional Python modules to be installed - ${ADDITIONAL_PYTHON_MODULES:-}"
echo "python3 -m pip install --upgrade ${ADDITIONAL_PYTHON_MODULES:-}" >> "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh"
fi
########### END enhance-image.sh ###########

# Check if config has changed since last run
echo "--- Checking for changes to the Sentry configuration ---"
if [ ! -f "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.py" ]; then
echo "  - Sentry sentry.conf.py config file does not yet exist"
mv -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py" "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.py"
rm -f ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
elif ! cmp -s "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py" "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.py"; then
echo "  - Sentry sentry.conf.py config file has been modified"
mv -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py" "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.py"
rm -f ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
else
echo "  - Sentry sentry.conf.py config file has not changed"
fi
if [ ! -f "${SENTRY_DATA_PATH}/self_hosted/sentry/config.yml" ]; then
echo "  - Sentry config.yml config file does not yet exist"
mv -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.yml"
rm -f ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
elif ! cmp -s "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.yml"; then
echo "  - Sentry config.yml config file has been modified"
mv -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.yml"
rm -f ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
else
echo "  - Sentry config.yml config file has not changed"
fi
if [ ! -f "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.sh" ]; then
echo "  - Sentry enhance-image.sh config file does not yet exist"
mv -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh" "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.sh"
rm -f ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
elif ! cmp -s "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh" "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.sh"; then
echo "  - Sentry enhance-image.sh config file has been modified"
mv -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh" "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.sh"
rm -f ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
else
echo "  - Sentry enhance-image.sh config file has not changed"
fi
echo

if [ "${EXEC_NUCLEAR_CLEAN:-}" = "true" ]; then
echo "--- Running a nuclear clean of the Kafka and Zookeeper volumes ---"
${docker_cmd:?} compose down --volumes --remove-orphans
${docker_cmd:?} volume rm sentry-kafka || true
${docker_cmd:?} volume rm sentry-zookeeper || true
rm -f ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
fi

if ! ${docker_cmd:?} images | grep -q 'sentry-self-hosted-local'; then
echo "--- The sentry-self-hosted-local image does not exist, forcing a re-install ---"
rm -f ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
fi

echo "--- Sentry installation ---"
cd ${SENTRY_DATA_PATH}/self_hosted
export REPORT_SELF_HOSTED_ISSUES=0
if [ "$(cat ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt 2> /dev/null)" != "${SENTRY_VERSION}" ]; then
echo "  - Running Sentry installation"
${install_cmd:?}
echo "${SENTRY_VERSION}" > ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
elif [ "X${FORCE_RUN_INSTALL_SCRIPT:-}" != "X" ]; then
echo "  - Running Sentry installation due to FORCE_RUN_INSTALL_SCRIPT"
${install_cmd:?}
echo "${SENTRY_VERSION}" > ${SENTRY_DATA_PATH}/self_hosted/.z-installed-sentry-version.txt
else
echo "  - Skipping Sentry installation as the current installed version is what we are about to start and nothing has changed"
fi
echo

echo "--- Create Initial Admin User ---"
if [ "${SKIP_ADMIN_USER_CREATE:-}" = "true" ]; then
echo "  - Container configured to skip admin user creation"
else
if [ ! -f "${SENTRY_DATA_PATH}/self_hosted/.z-initial-admin-generated.txt" ]; then
    echo "  - Generating initial admin user credentials"
    temp_password=$(echo "$(date +%s.%N) $(shuf -n1 -i0-999999)" | sha256sum | base64 | head -c 16)
    cd ${SENTRY_DATA_PATH}/self_hosted
    ${docker_cmd:?} compose run --rm web sentry createuser --email "${SENTRY_INITIAL_ADMIN_EMAIL:?}" --password "${temp_password:?}" --superuser || true
    echo "  - Created user ${SENTRY_INITIAL_ADMIN_EMAIL:?} with temporary password ${temp_password:?}"
    echo "${SENTRY_VERSION}" > ${SENTRY_DATA_PATH}/self_hosted/.z-initial-admin-generated.txt
else
    echo "  - The initial admin user was already created"
fi
fi
echo

echo "--- Starting Sentry services ---"
cd ${SENTRY_DATA_PATH}/self_hosted
if [ "${ALWAYS_FORCE_RECREATE:-}" = "true" ]; then
echo "  - Forcing recreation of whole stack"
${docker_cmd:?} compose --env-file .env.custom up --detach --remove-orphans --force-recreate
else
echo "  - Starting existing stack"
${docker_cmd:?} compose --env-file .env.custom up --detach --remove-orphans
echo "  - Forcing recreation of nginx proxy in stack"
${docker_cmd:?} compose --env-file .env.custom up --detach --force-recreate nginx
fi
echo

echo "--- Configure DIND Networking ---"
if [ "${RUN_WITH_DIND:-}" = "true" ]; then
echo "  - Connecting DIND container to private Sentry overlay network"
${DIND_NET_CONN_CMD:?} 2> /dev/null || true
sleep 10
else
echo "  - Service configured to run on host docker socket. No DIND container network config required."
fi
echo

echo "--- Configure Redis memory usage ---"
if [ "${REDIS_MEMLIMIT}" != "0" ]; then
echo "  - Configure Redis maxmemory-policy to volatile-ttl"
${docker_cmd:?} compose exec redis redis-cli CONFIG SET maxmemory-policy volatile-ttl
echo "  - Configure Redis maxmemory to ${REDIS_MEMLIMIT}"
${docker_cmd:?} compose exec redis redis-cli CONFIG SET maxmemory ${REDIS_MEMLIMIT}
else
echo "  - Nothing to configure for Redis service"
fi

echo "--- Mark Sentry as running ---"
echo "1" > "${SENTRY_DATA_PATH}/self_hosted/.z-manager-service-running.txt"
echo

echo "--- Configure compose stack monitor ---"
_stack_monitor() {
echo "--- Waiting for child services to exit ---"
cd ${SENTRY_DATA_PATH}/self_hosted
while true; do
    # Check if any service has exited with a non-zero status code
    echo "--- Check if any service has exited with a non-zero status code ---"
    ignored_services="geoipupdate|place_holder"
    exited_services=$(${docker_cmd:?} compose ps --all --filter "status=exited" | grep -v "^NAME" | grep -v "Exit 0" | grep -vE "${ignored_services:?}" || true)
    if [ "X${exited_services}" != "X" ]; then
    echo "  - Some services have exited with a non-zero status. Exit!"
    exit 123
    fi
    # Check if the main services have exited
    echo "--- Check that the main services are still up ---"
    services="$(${docker_cmd:?} compose config --services | grep -vE "${ignored_services:?}")"
    # Loop through each service to check its status
    for service in $services; do
    # Use docker compose ps to check if the service is running
    service_status=$(${docker_cmd:?} compose ps --format "table {{.Service}} {{.Status}}" | grep $service || true)
    case $service_status in
        *Up*)
        echo "  - Service $service is up and running.";
        continue;
        ;;
        *)
        echo "  - Service $service is NOT running. Exit!";
        exit 123;
        ;;
    esac
    done
    sleep 60
    echo
done
}
sleep 10
_stack_monitor
echo "--- Stopping manager service ---"
