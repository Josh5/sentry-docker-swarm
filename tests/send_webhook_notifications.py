#!/usr/bin/env python3
"""Manually send representative supervisor warnings and errors to configured webhooks."""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SUPERVISOR_PATH = PROJECT_ROOT / "docker" / "overlay" / "defaults" / "supervisor" / "supervisor.py"
SPEC = importlib.util.spec_from_file_location("sentry_supervisor_webhook_test", SUPERVISOR_PATH)
assert SPEC is not None and SPEC.loader is not None
SUPERVISOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SUPERVISOR
SPEC.loader.exec_module(SUPERVISOR)

SUPPORTED_WEBHOOK_TYPES = {"discord", "google-chat"}


def read_dotenv_value(path: Path, variable: str) -> str:
    value = ""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise RuntimeError(f"Unable to read {path}: {error}") from error

    for line in lines:
        candidate = line.strip()
        if not candidate or candidate.startswith("#"):
            continue
        if candidate.startswith("export "):
            candidate = candidate.removeprefix("export ").lstrip()
        name, separator, raw_value = candidate.partition("=")
        if not separator or name.strip() != variable:
            continue

        raw_value = raw_value.strip()
        if len(raw_value) >= 2 and raw_value[0] == raw_value[-1] and raw_value[0] in {'"', "'"}:
            value = raw_value[1:-1]
        else:
            value = raw_value.split(" #", maxsplit=1)[0].strip()
    return value


def main() -> int:
    try:
        configured_urls = read_dotenv_value(PROJECT_ROOT / ".env", "NOTIFY_WEBHOOK_URLS")
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 2

    endpoints = list(filter(None, re.split(r"[,\s]+", configured_urls)))
    if not endpoints:
        print("Set NOTIFY_WEBHOOK_URLS in the project-root .env before running this command.", file=sys.stderr)
        return 2

    events = (
        SUPERVISOR.NotificationEvent(
            service="webhook-format-test",
            display_name="Webhook format test",
            event_key="webhook-format-test",
            severity="warning",
            action="trigger",
            message=(
                "Webhook format test has failed 2 monitored observations. Automatic recovery will continue. "
                "The service remains unhealthy after an automatic restart."
            ),
        ),
        SUPERVISOR.NotificationEvent(
            service="webhook-format-test",
            display_name="Webhook format test",
            event_key="webhook-format-test",
            severity="error",
            action="trigger",
            message=(
                "Webhook format test has failed 3 monitored observations. Automatic recovery will continue. "
                "Human intervention is required."
            ),
        ),
        SUPERVISOR.NotificationEvent(
            service="webhook-format-test",
            display_name="Webhook format test",
            event_key="webhook-format-test",
            severity="error",
            action="resolve",
            message="Webhook format test has remained healthy and free of monitored issues for 10 minutes.",
        ),
    )

    attempted = 0
    failures = 0
    for endpoint in endpoints:
        if endpoint.count("://") != 1:
            failures += 1
            print(
                "FAIL malformed webhook destination: multiple URLs appear to be concatenated; "
                "separate them with a comma.",
                file=sys.stderr,
            )
            continue

        webhook_type, url = SUPERVISOR.classify_webhook(endpoint)
        if webhook_type not in SUPPORTED_WEBHOOK_TYPES:
            print(f"SKIP {webhook_type}: this command currently tests Discord and Google Chat only.")
            continue

        for event in events:
            attempted += 1
            payload = SUPERVISOR.build_webhook_payload(
                webhook_type,
                event,
                node_name="webhook-test-node",
                node_cluster="test",
            )
            result = SUPERVISOR.post_json(url, payload, f"test {webhook_type} webhook")
            status = f" HTTP {result.status_code}" if result.status_code is not None else ""
            if result.success:
                print(f"PASS {webhook_type} {event.severity}:{status or ' delivered'}")
            else:
                failures += 1
                print(f"FAIL {webhook_type} {event.severity}:{status} {result.detail}", file=sys.stderr)

    if attempted == 0:
        print("No supported Discord or Google Chat webhook destinations were found.", file=sys.stderr)
        return 2
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
