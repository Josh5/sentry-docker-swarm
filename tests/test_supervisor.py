"""Focused tests for unified supervisor incident coordination."""

from __future__ import annotations

import importlib.util
import io
import logging
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

SUPERVISOR_PATH = Path(__file__).parents[1] / "docker" / "overlay" / "defaults" / "supervisor" / "supervisor.py"
SPEC = importlib.util.spec_from_file_location("sentry_supervisor", SUPERVISOR_PATH)
assert SPEC is not None and SPEC.loader is not None
SUPERVISOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SUPERVISOR
SPEC.loader.exec_module(SUPERVISOR)
logging.disable(logging.CRITICAL)


class IncidentCoordinatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.coordinator = SUPERVISOR.IncidentCoordinator()

    @staticmethod
    def unhealthy(service: str = "snuba") -> object:
        return SUPERVISOR.HealthObservation(
            service=service,
            display_name=service,
            healthy=False,
            reason="state=exited",
            needs_restart=True,
            recovery_kind="service",
        )

    @staticmethod
    def healthy(service: str = "snuba") -> object:
        return SUPERVISOR.HealthObservation(
            service=service,
            display_name=service,
            healthy=True,
            reason="state=running, health=healthy",
        )

    @staticmethod
    def log_error(service: str = "snuba") -> object:
        return SUPERVISOR.LogObservation(
            service=service,
            matches=(SUPERVISOR.LogMatch("abcdef123456", "error pattern", 1),),
        )

    def test_health_and_logs_share_one_incident_lifecycle(self) -> None:
        self.assertEqual(self.coordinator.observe_logs(self.log_error()), [])

        recoveries, notifications = self.coordinator.observe_health(self.unhealthy(), now=0)
        self.assertEqual(len(recoveries), 1)
        self.assertEqual(notifications, [])

        warning = self.coordinator.observe_logs(self.log_error())
        self.assertEqual(len(warning), 1)
        self.assertEqual(warning[0].severity, "warning")
        self.assertEqual(warning[0].event_key, "service-snuba")

        _, duplicate_warning = self.coordinator.observe_health(self.unhealthy(), now=121)
        self.assertEqual(duplicate_warning, [])

        error = self.coordinator.observe_logs(self.log_error())
        self.assertEqual(len(error), 1)
        self.assertEqual(error[0].severity, "error")
        self.assertEqual(error[0].event_key, "service-snuba")

    def test_resolution_waits_for_health_and_logs_to_clear(self) -> None:
        self.coordinator.observe_logs(self.log_error())
        self.coordinator.observe_logs(self.log_error())
        self.coordinator.observe_health(self.unhealthy(), now=0)

        no_resolution = self.coordinator.observe_logs(SUPERVISOR.LogObservation(service="snuba", matches=()))
        self.assertEqual(no_resolution, [])

        _, resolution = self.coordinator.observe_health(self.healthy(), now=121)
        self.assertEqual(len(resolution), 1)
        self.assertEqual(resolution[0].action, "resolve")
        self.assertEqual(resolution[0].event_key, "service-snuba")

    def test_different_services_never_share_incident_state(self) -> None:
        self.coordinator.observe_logs(self.log_error("snuba"))
        snuba_warning = self.coordinator.observe_logs(self.log_error("snuba"))
        self.assertEqual(len(snuba_warning), 1)

        relay_first = self.coordinator.observe_logs(self.log_error("relay"))
        self.assertEqual(relay_first, [])
        relay_warning = self.coordinator.observe_logs(self.log_error("relay"))
        self.assertEqual(len(relay_warning), 1)
        self.assertEqual(relay_warning[0].event_key, "service-relay")


class HealthCollectorTests(unittest.TestCase):
    def test_running_container_with_starting_health_is_given_startup_grace(self) -> None:
        collector = SUPERVISOR.HealthCollector(object(), object())
        collector._dind_is_healthy = Mock(return_value=True)
        collector._services = Mock(return_value=["snuba"])
        collector._inspect_compose_containers = Mock(
            return_value=[
                {
                    "Config": {"Labels": {"com.docker.compose.service": "snuba"}},
                    "State": {"Status": "running", "Health": {"Status": "starting"}},
                    "RestartCount": 0,
                }
            ]
        )

        observation = next(item for item in collector.collect().observations if item.service == "snuba")

        self.assertTrue(observation.healthy)
        self.assertFalse(observation.needs_restart)
        self.assertIn("health=starting", observation.reason)


class NotificationDeliveryTests(unittest.TestCase):
    def test_warning_and_error_messages_use_production_formatting(self) -> None:
        warning = SUPERVISOR.NotificationEvent("service", "Service", "key", "warning", "trigger", "warning text")
        error = SUPERVISOR.NotificationEvent("service", "Service", "key", "error", "trigger", "error text")

        self.assertEqual(SUPERVISOR.format_notification_message(warning), "[WARNING] warning text")
        self.assertEqual(SUPERVISOR.format_notification_message(error), "[ERROR] error text")

    def test_discord_and_google_chat_urls_are_detected(self) -> None:
        discord_type, _ = SUPERVISOR.classify_webhook("https://discord.com/api/webhooks/id/token")
        google_type, _ = SUPERVISOR.classify_webhook("https://chat.googleapis.com/v1/spaces/id/messages?key=value")

        self.assertEqual(discord_type, "discord")
        self.assertEqual(google_type, "google-chat")

    def test_discord_payload_uses_a_rich_embed(self) -> None:
        event = SUPERVISOR.NotificationEvent(
            "snuba",
            "Snuba",
            "service-snuba",
            "error",
            "trigger",
            "Snuba remains unhealthy.",
            created_at=0,
        )

        payload = SUPERVISOR.build_webhook_payload("discord", event)
        embed = payload["embeds"][0]

        self.assertEqual(payload["username"], "Sentry Supervisor")
        self.assertEqual(embed["title"], "🚨 Sentry service error")
        self.assertEqual(embed["description"], event.message)
        self.assertEqual(embed["color"], 0xDC2626)
        self.assertEqual(embed["timestamp"], "1970-01-01T00:00:00Z")
        self.assertEqual(embed["fields"][0]["value"], "Snuba")

    def test_google_chat_payload_uses_a_rich_card(self) -> None:
        event = SUPERVISOR.NotificationEvent(
            "snuba",
            "Snuba",
            "service-snuba",
            "warning",
            "trigger",
            "Snuba matched <error>.",
            created_at=0,
        )

        payload = SUPERVISOR.build_webhook_payload(
            "google-chat",
            event,
            node_name="node-1",
            node_cluster="production",
        )
        card = payload["cardsV2"][0]["card"]

        self.assertEqual(payload["text"], "[production] Sentry service warning: Snuba")
        self.assertEqual(card["header"]["title"], "⚠️ Sentry service warning")
        self.assertEqual(card["header"]["subtitle"], "WARNING • production • node-1")
        self.assertEqual(card["sections"][0]["widgets"][0]["textParagraph"]["text"], "Snuba matched &lt;error&gt;.")
        source = card["sections"][0]["widgets"][1]["decoratedText"]
        self.assertEqual(source, {"topLabel": "Source", "text": "sentry-supervisor"})
        service = card["sections"][0]["widgets"][2]["decoratedText"]
        self.assertEqual(service, {"topLabel": "Service", "text": "Snuba", "bottomLabel": "snuba"})
        footer = card["sections"][1]["widgets"][0]["decoratedText"]
        self.assertEqual(footer["startIcon"], {"materialIcon": {"name": "schedule"}})
        self.assertEqual(footer["text"], "<b>Notification time:</b> 1970-01-01 00:00:00 UTC")

    def test_unknown_webhook_uses_plain_text_payload(self) -> None:
        event = SUPERVISOR.NotificationEvent("snuba", "Snuba", "service-snuba", "warning", "trigger", "Problem")

        self.assertEqual(SUPERVISOR.build_webhook_payload("generic", event), {"text": "[WARNING] Problem"})

    @patch.object(SUPERVISOR.urllib.request, "urlopen")
    def test_sender_sets_discord_compatible_headers(self, urlopen: Mock) -> None:
        response = Mock()
        response.status = 204
        response.read.return_value = b""
        urlopen.return_value.__enter__.return_value = response

        result = SUPERVISOR.post_json("https://example.invalid/webhook", {"content": "hello"}, "test")

        self.assertTrue(result.success)
        request = urlopen.call_args.args[0]
        self.assertEqual(request.get_header("User-agent"), SUPERVISOR.WEBHOOK_USER_AGENT)
        self.assertEqual(request.get_header("Content-type"), "application/json; charset=UTF-8")

    @patch.object(SUPERVISOR.urllib.request, "urlopen")
    def test_non_retryable_http_error_includes_response_body(self, urlopen: Mock) -> None:
        urlopen.side_effect = urllib.error.HTTPError(
            "https://example.invalid/webhook",
            403,
            "Forbidden",
            {},
            io.BytesIO(b'{"message": "blocked request"}'),
        )

        result = SUPERVISOR.post_json("https://example.invalid/webhook", {"content": "hello"}, "test")

        self.assertFalse(result.success)
        self.assertEqual(result.status_code, 403)
        self.assertIn("blocked request", result.detail)
        urlopen.assert_called_once()


if __name__ == "__main__":
    unittest.main()
