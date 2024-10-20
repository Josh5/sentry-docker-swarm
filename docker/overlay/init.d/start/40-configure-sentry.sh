#!/usr/bin/env bash
###
# File: 40-configure-sentry.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:23:14 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Monday, 21st October 2024 12:29:17 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Patch Docker Compose file ---"
if [ ! -f "${SENTRY_DATA_PATH}/self_hosted/docker-compose.original.yml" ]; then
    cp -fv "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.original.yml"
fi
cp -fv "${SENTRY_DATA_PATH}/self_hosted/docker-compose.original.yml" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"

echo "  - Patch Docker Compose file memory limits within the DIND container."
sed -i "/x-restart-policy: &restart_policy/a \ \ mem_limit: ${DIND_MEMLIMIT:-0}" \
    "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"

echo "--- Configure Sentry ---"

########### START .env ###########
echo "  - Generate .env.custom"
cp -fv "${SENTRY_DATA_PATH}"/self_hosted/.env "${SENTRY_DATA_PATH}"/self_hosted/.env.custom

echo "      - Adding additional config to .env"
echo -e "${SENTRY_ENV_CUSTOM:-}" >>"${SENTRY_DATA_PATH}"/self_hosted/.env.custom

echo "      - Patch Docker Compose file to read .env.custom on all services."
sed -i "/x-restart-policy: &restart_policy/a \ \ env_file: [.env.custom]" "${SENTRY_DATA_PATH}/self_hosted/docker-compose.yml"
########### END .env ###########

########### START sentry.conf.py ###########
echo "  - Generate sentry.conf.tmp.py"
cp -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.example.py" "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
# Import Bool
sed -i "/from sentry\.conf\.server import \*/a from sentry.utils.types import Bool" "${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"

####################
# CUSTOM OVERRIDES #
####################

EOF

if [ "${SENTRY_BEACON_DISABLED:-}" = "true" ]; then
    echo "      - Disable Sentry beacon"
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
# Disable the stats telemetry beacon for self-hosted installations
SENTRY_BEACON=False
EOF
else
    echo "      - Keeping Sentry beacon default config"
fi

if [ "${SENTRY_CUSTOM_DB_CONFIG:-}" = "true" ]; then
    echo "      - Configure custom DB connection details"
    cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
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
    echo "      - Keeping Sentry DB default config"
fi

echo "      - Configure data retention to ${SENTRY_EVENT_RETENTION_DAYS:?} days"
sed -i "s|^SENTRY_EVENT_RETENTION_DAYS=.*|SENTRY_EVENT_RETENTION_DAYS=${SENTRY_EVENT_RETENTION_DAYS:?}|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom

echo "      - Configure Sentry feature set to the ${SENTRY_COMPOSE_PROFILES:?} profile"
sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${SENTRY_COMPOSE_PROFILES:?}|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom

echo "      - Configure SSL proxy X-Forwarded-Proto header"
cat <<EOF >>"${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SOCIAL_AUTH_REDIRECT_IS_HTTPS = True
EOF

echo "      - Insert 'SENTRY_CONF_CUSTOM' contents"
echo -e "${SENTRY_CONF_CUSTOM:-}" >>"${SENTRY_DATA_PATH}/self_hosted/sentry/sentry.conf.tmp.py"
########### END sentry.conf.py ###########

########### START config.yml ###########
echo "  - Generate config.tmp.yml"
cp -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/config.example.yml" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
yq eval -i "... comments=\"\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"

# Configure secret key
echo "      - Configure secret key"
yq eval -i ".\"system.secret-key\" = \"${SENTRY_SECRET_KEY:-supersecretkey}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"

# Configure URL prefix
echo "      - Configure URL prefix"
yq eval -i ".\"system.url-prefix\" = \"${SENTRY_URL_PREFIX:-http://web:9000}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"

# Configure Mail
echo "      - Configure mail details"
yq eval -i ".\"mail.from\" = \"${SENTRY_SERVER_EMAIL:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
if [ "${SENTRY_CUSTOM_MAIL_SERVER_CONFIG:-}" = "true" ]; then
    echo "      - Configure custom smtp mail server"
    sed -i "s|^SENTRY_MAIL_HOST=.*|# SENTRY_MAIL_HOST=example.com|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
    yq eval -i ".\"mail.backend\" = \"smtp\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
    yq eval -i ".\"mail.host\" = \"${SENTRY_EMAIL_HOST:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
    yq eval -i ".\"mail.port\" = ${SENTRY_EMAIL_PORT:?}" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
    yq eval -i ".\"mail.username\" = \"${SENTRY_EMAIL_USER:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
    yq eval -i ".\"mail.password\" = \"${SENTRY_EMAIL_PASSWORD:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
    yq eval -i ".\"mail.use-tls\" = ${SENTRY_EMAIL_USE_TLS:?}" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
    yq eval -i ".\"mail.use-ssl\" = ${SENTRY_EMAIL_USE_SSL:?}" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
else
    echo "      - Keeping Sentry mail default config"
    echo "      - Configure Sentry mail host to ${SENTRY_MAIL_HOST:?}"
    sed -i "s|^# SENTRY_MAIL_HOST=.*|SENTRY_MAIL_HOST=${SENTRY_MAIL_HOST:?}|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
    sed -i "s|^SENTRY_MAIL_HOST=.*|SENTRY_MAIL_HOST=${SENTRY_MAIL_HOST:?}|" "${SENTRY_DATA_PATH}"/self_hosted/.env.custom
fi

# Configure Filestore
if [ "X${SENTRY_FILESTORE_BACKEND_S3_BUCKET:-}" != "X" ]; then
    echo "      - Configure custom Sentry S3 filestore backend"
    yq eval -i ".\"filestore.backend\" = \"s3\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
    yq eval -i ".\"filestore.options\".bucket_name = \"${SENTRY_FILESTORE_BACKEND_S3_BUCKET:?}\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
    yq eval -i ".\"filestore.options\".default_acl = \"private\"" "${SENTRY_DATA_PATH}/self_hosted/sentry/config.tmp.yml"
else
    echo "      - Keeping Sentry filestore backend default config"
fi
########### END config.yml ###########

########### START enhance-image.sh ###########
echo "  - Generate enhance-image.sh"
cp -fv "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.example.sh" "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh"
chmod +x "${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh"

if [ "X${ADDITIONAL_APT_PACKAGES:-}" != "X" ]; then
    echo "      - Adding additional APT packages to be installed - ${ADDITIONAL_APT_PACKAGES:-}"
    echo "apt-get update && apt-get install -y ${ADDITIONAL_APT_PACKAGES:-}" >>"${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh"
else
    echo "      - No additional APT packages to be installed with the 'ADDITIONAL_APT_PACKAGES' variable."
fi
if [ "X${ADDITIONAL_PYTHON_MODULES:-}" != "X" ]; then
    echo "      - Adding additional Python modules to be installed - ${ADDITIONAL_PYTHON_MODULES:-}"
    echo "python3 -m pip install --upgrade ${ADDITIONAL_PYTHON_MODULES:-}" >>"${SENTRY_DATA_PATH}/self_hosted/sentry/enhance-image.tmp.sh"
else
    echo "      - No additional Python modules to be installed with the 'ADDITIONAL_PYTHON_MODULES' variable."
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
