#!/bin/sh
###
# File: entrypoint.sh
# Project: vmagent
#
# Configures vmagent to scrape the nested DinD cAdvisor service and forward
# those metrics to the configured Prometheus-compatible remote_write endpoint.
###
set -eu

if [ -z "${SENTRY_METRICS_FORWARD_REMOTE_WRITE_URL:-}" ]; then
    echo "SENTRY_METRICS_FORWARD_REMOTE_WRITE_URL is required" >&2
    exit 1
fi

mkdir -p /etc/vmagent
cat >/etc/vmagent/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  external_labels:
    node_id: "${NODE_ID:-default}"
    node_name: "${NODE_NAME:-default}"
    node_cluster: "${NODE_CLUSTER:-default}"
    container_runtime: "dind"
scrape_configs:
  - job_name: cadvisor-dind
    max_scrape_size: 64MB
    static_configs:
      - targets: ["cadvisor:8080"]
    metric_relabel_configs:
      - source_labels: [name]
        regex: (.+)
        target_label: container_name
        replacement: \$1
      - source_labels: [name]
        regex: (.+)
        target_label: workload_name
        replacement: \$1
      - source_labels: [container_label_com_docker_compose_project]
        regex: (.+)
        target_label: workload_group
        replacement: \$1
      - source_labels: [container_label_com_docker_compose_service]
        regex: (.+)
        target_label: workload_name
        replacement: \$1
EOF

set -- /vmagent-prod \
    -promscrape.config=/etc/vmagent/prometheus.yml \
    "-remoteWrite.url=${SENTRY_METRICS_FORWARD_REMOTE_WRITE_URL}" \
    -promscrape.maxScrapeSize=64MB \
    -remoteWrite.maxDiskUsagePerURL=1GB \
    -remoteWrite.tmpDataPath=/vmagent-remotewrite-data \
    -httpListenAddr=:8429

if [ -n "${SENTRY_METRICS_FORWARD_REMOTE_WRITE_BASIC_AUTH_USER:-}" ] &&
    [ -n "${SENTRY_METRICS_FORWARD_REMOTE_WRITE_BASIC_AUTH_PASS:-}" ]; then
    set -- "$@" \
        "-remoteWrite.basicAuth.username=${SENTRY_METRICS_FORWARD_REMOTE_WRITE_BASIC_AUTH_USER}" \
        "-remoteWrite.basicAuth.password=${SENTRY_METRICS_FORWARD_REMOTE_WRITE_BASIC_AUTH_PASS}"
fi

exec "$@"
