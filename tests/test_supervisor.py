"""Focused tests for unified supervisor incident coordination."""

from __future__ import annotations

import importlib.util
import logging
import sys
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
