#!/bin/sh
###
# File: send.sh
# Project: notifications
#
# Sends warning/error notifications to configured webhooks and error
# trigger/resolve events to PagerDuty.
###
set -eu

severity="${1:-}"
component="${2:-sentry-manager}"
event_key="${3:-${component}}"
message="${4:-No notification message provided}"
action="${5:-trigger}"

case "${severity}" in
warning | error) ;;
*)
    echo "Unsupported notification severity '${severity}'. Expected warning or error." >&2
    exit 1
    ;;
esac

case "${action}" in
trigger | resolve) ;;
*)
    echo "Unsupported notification action '${action}'. Expected trigger or resolve." >&2
    exit 1
    ;;
esac

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [ "${action}" = "resolve" ]; then
    formatted_message="[RESOLVED] ${component}: ${message}"
else
    formatted_message="[$(printf '%s' "${severity}" | tr '[:lower:]' '[:upper:]')] ${component}: ${message}"
fi

escaped_message=$(json_escape "${formatted_message}")
escaped_severity=$(json_escape "${severity}")
escaped_component=$(json_escape "${component}")
escaped_event_key=$(json_escape "${event_key}")

webhook_urls=$(printf '%s' "${NOTIFY_WEBHOOK_URLS:-}" | tr ',' ' ')
for endpoint in ${webhook_urls}; do
    webhook_type=""
    webhook_url="${endpoint}"

    case "${endpoint}" in
    discord=*)
        webhook_type="discord"
        webhook_url="${endpoint#discord=}"
        ;;
    google-chat=* | google_chat=*)
        webhook_type="google-chat"
        webhook_url="${endpoint#*=}"
        ;;
    slack=*)
        webhook_type="slack"
        webhook_url="${endpoint#slack=}"
        ;;
    generic=*)
        webhook_type="generic"
        webhook_url="${endpoint#generic=}"
        ;;
    esac

    if [ -z "${webhook_type}" ]; then
        case "${webhook_url}" in
        *discord.com/api/webhooks/* | *discordapp.com/api/webhooks/*) webhook_type="discord" ;;
        *chat.googleapis.com/*) webhook_type="google-chat" ;;
        *hooks.slack.com/*) webhook_type="slack" ;;
        *) webhook_type="generic" ;;
        esac
    fi

    case "${webhook_type}" in
    discord)
        payload="{\"content\":\"${escaped_message}\"}"
        ;;
    google-chat | slack)
        payload="{\"text\":\"${escaped_message}\"}"
        ;;
    *)
        payload="{\"severity\":\"${escaped_severity}\",\"component\":\"${escaped_component}\",\"event_key\":\"${escaped_event_key}\",\"action\":\"${action}\",\"message\":\"${escaped_message}\"}"
        ;;
    esac

    wget --header="Content-Type: application/json" \
        --post-data "${payload}" \
        --timeout=10 --tries=1 \
        -qO /dev/null "${webhook_url}" ||
        echo "Failed to send ${severity} notification to ${webhook_type} webhook." >&2
done

if [ -n "${PAGERDUTY_INTEGRATION_KEY:-}" ]; then
    pagerduty_dedup_key="sentry-docker-swarm:${event_key}"
    escaped_routing_key=$(json_escape "${PAGERDUTY_INTEGRATION_KEY}")
    escaped_dedup_key=$(json_escape "${pagerduty_dedup_key}")

    if [ "${action}" = "resolve" ] && [ "${severity}" = "error" ]; then
        pagerduty_payload="{\"routing_key\":\"${escaped_routing_key}\",\"event_action\":\"resolve\",\"dedup_key\":\"${escaped_dedup_key}\"}"
    elif [ "${severity}" = "error" ]; then
        escaped_source=$(json_escape "${NODE_NAME:-sentry-manager}")
        pagerduty_payload="{\"routing_key\":\"${escaped_routing_key}\",\"event_action\":\"trigger\",\"dedup_key\":\"${escaped_dedup_key}\",\"payload\":{\"summary\":\"${escaped_message}\",\"source\":\"${escaped_source}\",\"severity\":\"error\",\"component\":\"${escaped_component}\",\"group\":\"sentry\"}}"
    else
        pagerduty_payload=""
    fi

    if [ -n "${pagerduty_payload}" ]; then
        wget --header="Content-Type: application/json" \
            --post-data "${pagerduty_payload}" \
            --timeout=10 --tries=1 \
            -qO /dev/null https://events.pagerduty.com/v2/enqueue ||
            echo "Failed to send PagerDuty ${action} event." >&2
    fi
fi
