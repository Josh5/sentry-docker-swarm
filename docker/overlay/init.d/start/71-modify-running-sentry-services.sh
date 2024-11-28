#!/usr/bin/env bash
###
# File: 71-modify-running-sentry-services.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:42:08 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Friday, 29th November 2024 3:03:57 am
# Modified By: Josh5 (jsunnex@gmail.com)
###

echo "--- Configure DIND Networking ---"
echo "  - Connecting DIND container to private Sentry overlay network"
${DIND_NET_CONN_CMD:?} 2>/dev/null || true
sleep 10 &
wait $!
echo

echo "--- Configure Redis memory usage ---"
if [ "${REDIS_MEMLIMIT:-}" != "0" ]; then
    echo "  - Configure Redis maxmemory-policy to volatile-lru"
    ${docker_compose_cmd:?} exec redis redis-cli CONFIG SET maxmemory-policy volatile-lru
    echo "  - Configure Redis maxmemory to ${REDIS_MEMLIMIT}"
    ${docker_compose_cmd:?} exec redis redis-cli CONFIG SET maxmemory ${REDIS_MEMLIMIT:?}
    if [ -f "${SENTRY_DATA_PATH:?}"/self_hosted/redis.conf ]; then
        # From v24.11.1, there is a redis.conf file to persist this configuration
        sed -i "s|^maxmemory.*|maxmemory ${REDIS_MEMLIMIT:?}|" "${SENTRY_DATA_PATH:?}"/self_hosted/redis.conf
    fi
else
    echo "  - Nothing to configure for Redis service. No value set in 'REDIS_MEMLIMIT' env variable."
fi
