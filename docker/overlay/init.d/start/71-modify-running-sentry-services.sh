#!/usr/bin/env bash
###
# File: 71-modify-running-sentry-services.sh
# Project: init.d
# File Created: Monday, 21st October 2024 11:42:08 am
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Tuesday, 3rd June 2025 1:21:02 pm
# Modified By: Josh.5 (jsunnex@gmail.com)
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
else
    echo "  - Nothing to configure for Redis service. No value set in 'REDIS_MEMLIMIT' env variable."
fi
