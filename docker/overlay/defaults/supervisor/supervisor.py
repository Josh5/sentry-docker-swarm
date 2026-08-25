#!/usr/bin/env python3
"""Persistent Sentry service supervisor for the nested Docker daemon."""

from __future__ import annotations

import json
import logging
import os
import queue
import re
import shlex
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.request
from collections import defaultdict, deque
from collections.abc import Callable, Iterable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path

HEALTH_INTERVAL_SECONDS = 30
LOG_INTERVAL_SECONDS = 60
SERVICE_RECHECK_SECONDS = 120
FAILURE_WINDOW_SECONDS = 600
WARNING_OBSERVATION = 2
ERROR_OBSERVATION = 3
INITIAL_LOG_LOOKBACK_SECONDS = 180
MAX_LOG_COLLECTORS = 4
DIND_PROBE_TIMEOUT_SECONDS = 10

LOG = logging.getLogger("sentry-supervisor")


class CommandError(RuntimeError):
    """Raised when a managed command does not complete successfully."""


class CommandRunner:
    def run(self, args: Sequence[str], *, timeout: int = 30) -> subprocess.CompletedProcess[str]:
        try:
            completed = subprocess.run(
                list(args),
                check=False,
                capture_output=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise CommandError(f"Command failed: {shlex.join(args)}: {error}") from error

        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout).strip()[-1000:]
            raise CommandError(
                f"Command exited {completed.returncode}: {shlex.join(args)}{': ' + detail if detail else ''}"
            )
        return completed

    def run_shell(self, command: str, *, timeout: int = 120) -> subprocess.CompletedProcess[str]:
        return self.run(["/bin/sh", "-c", command], timeout=timeout)


@dataclass(frozen=True)
class SupervisorConfig:
    data_path: Path
    dind_name: str
    dind_socket: Path
    compose_file: Path
    compose_custom_file: Path
    compose_env_file: Path
    log_config_file: Path
    enable_log_monitor: bool
    web_only_maintenance_mode: bool
    notify_webhook_urls: str
    pagerduty_integration_key: str
    node_name: str
    dind_run_command: str
    dind_network_connect_command: str
    services_cpu_quota: str
    cpu_period: str
    dind_cpu_shares: str

    @classmethod
    def from_environment(cls) -> SupervisorConfig:
        data_path = Path(os.environ["SENTRY_DATA_PATH"])
        self_hosted = data_path / "self_hosted"
        return cls(
            data_path=data_path,
            dind_name=os.environ.get("DIND_CONTAINER_NAME", "sentry-swarm-dind"),
            dind_socket=data_path / "docker-sock" / "docker.sock",
            compose_file=self_hosted / "docker-compose.yml",
            compose_custom_file=self_hosted / "docker-compose.custom.yml",
            compose_env_file=self_hosted / ".env.custom",
            log_config_file=Path("/defaults/log-monitor/config.json"),
            enable_log_monitor=os.environ.get("ENABLE_LOG_MONITOR", "false").lower() == "true",
            web_only_maintenance_mode=os.environ.get("WEB_ONLY_MAINTENANCE_MODE", "false").lower() == "true",
            notify_webhook_urls=os.environ.get("NOTIFY_WEBHOOK_URLS", ""),
            pagerduty_integration_key=os.environ.get("PAGERDUTY_INTEGRATION_KEY", ""),
            node_name=os.environ.get("NODE_NAME", "sentry-manager"),
            dind_run_command=os.environ["DIND_RUN_CMD"],
            dind_network_connect_command=os.environ["DIND_NET_CONN_CMD"],
            services_cpu_quota=os.environ["SERVICES_CPU_QUOTA"],
            cpu_period=os.environ["CPU_PERIOD"],
            dind_cpu_shares=os.environ.get("DIND_CPU_SHARES", "512"),
        )

    @property
    def inner_docker(self) -> list[str]:
        return ["docker", "--host", f"unix://{self.dind_socket}"]

    @property
    def compose(self) -> list[str]:
        return self.inner_docker + [
            "compose",
            "-f",
            str(self.compose_file),
            "-f",
            str(self.compose_custom_file),
            "--env-file",
            str(self.compose_env_file),
        ]


@dataclass(frozen=True)
class LogMatch:
    container_id: str
    pattern: str
    count: int


@dataclass(frozen=True)
class HealthObservation:
    service: str
    display_name: str
    healthy: bool
    reason: str
    restart_total: int = 0
    needs_restart: bool = False
    recovery_kind: str | None = None
    event_key: str | None = None
    recheck_seconds: int = SERVICE_RECHECK_SECONDS


@dataclass(frozen=True)
class LogObservation:
    service: str
    matches: tuple[LogMatch, ...] = ()
    available: bool = True


@dataclass(frozen=True)
class HealthBatch:
    observations: tuple[HealthObservation, ...]
    collected_at: float = field(default_factory=time.time)


@dataclass(frozen=True)
class LogBatch:
    observations: tuple[LogObservation, ...]


@dataclass(frozen=True)
class RecoveryRequest:
    service: str
    kind: str
    reason: str


@dataclass(frozen=True)
class NotificationEvent:
    service: str
    display_name: str
    event_key: str
    severity: str
    action: str
    message: str


@dataclass
class ServiceIncident:
    service: str
    display_name: str
    event_key: str
    health_failures: deque[float] = field(default_factory=deque)
    log_failure_count: int = 0
    health_active: bool = False
    log_active: bool = False
    health_reason: str = ""
    log_reason: str = ""
    alert_level: str = "none"
    restart_total: int | None = None
    next_health_evaluation: float = 0.0


class IncidentCoordinator:
    """Combines all observations into one incident lifecycle per service."""

    def __init__(self) -> None:
        self.states: dict[str, ServiceIncident] = {}

    def observe_health(
        self, observation: HealthObservation, *, now: float | None = None
    ) -> tuple[list[RecoveryRequest], list[NotificationEvent]]:
        timestamp = time.time() if now is None else now
        state = self._state(
            observation.service,
            observation.display_name,
            observation.event_key or f"service-{observation.service}",
        )

        if timestamp < state.next_health_evaluation:
            return [], []

        automatic_restart = state.restart_total is not None and observation.restart_total > state.restart_total
        state.restart_total = observation.restart_total
        failed = not observation.healthy or automatic_restart
        recoveries: list[RecoveryRequest] = []

        if failed:
            while state.health_failures and timestamp - state.health_failures[0] > FAILURE_WINDOW_SECONDS:
                state.health_failures.popleft()
            state.health_failures.append(timestamp)
            state.health_active = True
            state.health_reason = (
                f"Docker restart count increased to {observation.restart_total}"
                if automatic_restart and observation.healthy
                else observation.reason
            )
            LOG.warning("%s health observation failed: %s", state.display_name, state.health_reason)
            state.next_health_evaluation = timestamp + observation.recheck_seconds
            if observation.needs_restart and observation.recovery_kind:
                recoveries.append(
                    RecoveryRequest(
                        service=observation.service,
                        kind=observation.recovery_kind,
                        reason=state.health_reason,
                    )
                )
        else:
            if state.health_active:
                LOG.info("%s health observation recovered", state.display_name)
            state.health_active = False
            state.health_reason = ""
            state.health_failures.clear()
            state.next_health_evaluation = 0.0

        return recoveries, self._evaluate(state)

    def observe_logs(self, observation: LogObservation) -> list[NotificationEvent]:
        if not observation.available:
            return []

        state = self._state(
            observation.service,
            observation.service,
            f"service-{observation.service}",
        )
        if observation.matches:
            state.log_active = True
            state.log_failure_count += 1
            state.log_reason = self._summarize_matches(observation.matches)
            LOG.warning("%s log observation failed: %s", state.display_name, state.log_reason)
        else:
            if state.log_active:
                LOG.info("%s log observation recovered", state.display_name)
            state.log_active = False
            state.log_failure_count = 0
            state.log_reason = ""
        return self._evaluate(state)

    def defer_health_evaluation(self, service: str, until: float) -> None:
        state = self.states.get(service)
        if state is not None:
            state.next_health_evaluation = max(state.next_health_evaluation, until)

    def _state(self, service: str, display_name: str, event_key: str) -> ServiceIncident:
        state = self.states.get(service)
        if state is None:
            state = ServiceIncident(service, display_name, event_key)
            self.states[service] = state
        return state

    def _evaluate(self, state: ServiceIncident) -> list[NotificationEvent]:
        active = state.health_active or state.log_active
        if not active:
            if state.alert_level == "none":
                return []
            previous_level = state.alert_level
            state.alert_level = "none"
            LOG.info("Resolving %s incident", state.display_name)
            return [
                NotificationEvent(
                    service=state.service,
                    display_name=state.display_name,
                    event_key=state.event_key,
                    severity=previous_level,
                    action="resolve",
                    message=f"{state.display_name} is healthy and no new configured log errors are present.",
                )
            ]

        observation_count = max(len(state.health_failures), state.log_failure_count)
        desired_level = (
            "error"
            if observation_count >= ERROR_OBSERVATION
            else "warning"
            if observation_count >= WARNING_OBSERVATION
            else "none"
        )
        if desired_level == "none" or desired_level == state.alert_level:
            return []
        if state.alert_level == "error":
            return []
        if state.alert_level == "warning" and desired_level != "error":
            return []

        state.alert_level = desired_level
        evidence = "; ".join(
            reason
            for reason in (
                f"health: {state.health_reason}" if state.health_active else "",
                f"logs: {state.log_reason}" if state.log_active else "",
            )
            if reason
        )
        LOG.warning("Escalating %s incident to %s", state.display_name, desired_level)
        return [
            NotificationEvent(
                service=state.service,
                display_name=state.display_name,
                event_key=state.event_key,
                severity=desired_level,
                action="trigger",
                message=(
                    f"{state.display_name} has failed {observation_count} monitored observations. "
                    f"Automatic recovery will continue. {evidence}"
                ),
            )
        ]

    @staticmethod
    def _summarize_matches(matches: Iterable[LogMatch]) -> str:
        return "; ".join(
            f"{match.container_id[:12]} matched /{match.pattern}/ on {match.count} line(s)" for match in matches
        )


class NotificationHandler:
    def __init__(self, config: SupervisorConfig) -> None:
        self.webhook_urls = config.notify_webhook_urls
        self.pagerduty_key = config.pagerduty_integration_key
        self.node_name = config.node_name
        self.events: queue.Queue[NotificationEvent | None] = queue.Queue()
        self.worker = threading.Thread(target=self._run, name="notification-handler", daemon=True)

    def start(self) -> None:
        self.worker.start()

    def enqueue(self, event: NotificationEvent) -> None:
        self.events.put(event)

    def close(self) -> None:
        self.events.put(None)
        self.worker.join(timeout=2)

    def _run(self) -> None:
        while True:
            event = self.events.get()
            if event is None:
                return
            try:
                self._send(event)
            except Exception:
                LOG.exception("Notification handler failed for %s", event.event_key)

    def _send(self, event: NotificationEvent) -> None:
        formatted = (
            f"[RESOLVED] {event.message}"
            if event.action == "resolve"
            else f"[{event.severity.upper()}] {event.message}"
        )
        for endpoint in filter(None, re.split(r"[,\s]+", self.webhook_urls)):
            webhook_type, url = self._classify_webhook(endpoint)
            payload = (
                {"content": formatted}
                if webhook_type == "discord"
                else {"text": formatted}
                if webhook_type in {"slack", "google-chat"}
                else {
                    "severity": event.severity,
                    "service": event.service,
                    "event_key": event.event_key,
                    "action": event.action,
                    "message": formatted,
                }
            )
            self._post(url, payload, f"{webhook_type} webhook")

        if not self.pagerduty_key:
            return
        dedup_key = f"sentry-docker-swarm:{event.event_key}"
        if event.action == "resolve" and event.severity == "error":
            payload = {
                "routing_key": self.pagerduty_key,
                "event_action": "resolve",
                "dedup_key": dedup_key,
            }
        elif event.action == "trigger" and event.severity == "error":
            payload = {
                "routing_key": self.pagerduty_key,
                "event_action": "trigger",
                "dedup_key": dedup_key,
                "payload": {
                    "summary": event.message,
                    "source": self.node_name,
                    "severity": "error",
                    "component": event.service,
                    "group": "sentry",
                },
            }
        else:
            return
        self._post("https://events.pagerduty.com/v2/enqueue", payload, "PagerDuty")

    @staticmethod
    def _classify_webhook(endpoint: str) -> tuple[str, str]:
        for prefix, webhook_type in (
            ("discord=", "discord"),
            ("google-chat=", "google-chat"),
            ("google_chat=", "google-chat"),
            ("slack=", "slack"),
            ("generic=", "generic"),
        ):
            if endpoint.startswith(prefix):
                return webhook_type, endpoint[len(prefix) :]
        if "discord.com/api/webhooks/" in endpoint or "discordapp.com/api/webhooks/" in endpoint:
            return "discord", endpoint
        if "chat.googleapis.com/" in endpoint:
            return "google-chat", endpoint
        if "hooks.slack.com/" in endpoint:
            return "slack", endpoint
        return "generic", endpoint

    @staticmethod
    def _post(url: str, payload: dict[str, object], destination: str) -> None:
        request = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        last_error: Exception | None = None
        for attempt in range(1, 4):
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    response.read()
                return
            except (OSError, urllib.error.URLError) as error:
                last_error = error
                if attempt < 3:
                    time.sleep(2)
        LOG.error("Failed to send notification to %s after 3 attempts: %s", destination, last_error)


class HealthCollector:
    def __init__(self, config: SupervisorConfig, runner: CommandRunner) -> None:
        self.config = config
        self.runner = runner

    def collect(self) -> HealthBatch:
        if not self._dind_is_healthy():
            return HealthBatch(
                (
                    HealthObservation(
                        service="__dind__",
                        display_name="Sentry DinD",
                        healthy=False,
                        reason="The nested Docker daemon is not responding",
                        needs_restart=True,
                        recovery_kind="dind",
                        event_key="dind",
                    ),
                )
            )

        observations: list[HealthObservation] = [
            HealthObservation(
                service="__dind__",
                display_name="Sentry DinD",
                healthy=True,
                reason="The nested Docker daemon is responding",
                event_key="dind",
            )
        ]
        try:
            services = self._services()
            containers = self._inspect_compose_containers()
            observations.append(
                HealthObservation(
                    service="__compose__",
                    display_name="Sentry Compose discovery",
                    healthy=True,
                    reason="Compose service discovery is working",
                    event_key="compose-config",
                    recheck_seconds=HEALTH_INTERVAL_SECONDS,
                )
            )
        except CommandError as error:
            observations.append(
                HealthObservation(
                    service="__compose__",
                    display_name="Sentry Compose discovery",
                    healthy=False,
                    reason=str(error),
                    event_key="compose-config",
                    recheck_seconds=HEALTH_INTERVAL_SECONDS,
                )
            )
            return HealthBatch(tuple(observations))

        by_service: dict[str, list[dict[str, object]]] = defaultdict(list)
        for container in containers:
            labels = container.get("Config", {}).get("Labels", {}) or {}  # type: ignore[union-attr]
            service = labels.get("com.docker.compose.service")
            if service:
                by_service[str(service)].append(container)

        for service in services:
            service_containers = by_service.get(service, [])
            statuses: list[str] = []
            restart_total = 0
            healthy = bool(service_containers)
            for container in service_containers:
                state = container.get("State", {}) or {}
                status = str(state.get("Status", "unknown"))
                health_data = state.get("Health") or {}
                health = str(health_data.get("Status", "")) if isinstance(health_data, dict) else ""
                restart_total += int(container.get("RestartCount", 0) or 0)
                statuses.append(f"state={status}{', health=' + health if health else ''}")
                if status != "running" or health == "unhealthy":
                    healthy = False
            observations.append(
                HealthObservation(
                    service=service,
                    display_name=service,
                    healthy=healthy,
                    reason="; ".join(statuses) if statuses else "No container found",
                    restart_total=restart_total,
                    needs_restart=not healthy,
                    recovery_kind="service",
                )
            )
        return HealthBatch(tuple(observations))

    def _dind_is_healthy(self) -> bool:
        try:
            self.runner.run(
                ["docker", "exec", self.config.dind_name, "docker", "info"],
                timeout=DIND_PROBE_TIMEOUT_SECONDS,
            )
            return True
        except CommandError:
            return False

    def _services(self) -> list[str]:
        if self.config.web_only_maintenance_mode:
            return ["web", "nginx"]
        output = self.runner.run(self.config.compose + ["config", "--services"], timeout=20).stdout
        services = [
            service
            for service in output.splitlines()
            if service and not re.search(r"geoipupdate|place_holder", service)
        ]
        if not services:
            raise CommandError("Compose returned no monitored services")
        return services

    def _inspect_compose_containers(self) -> list[dict[str, object]]:
        output = self.runner.run(
            self.config.inner_docker
            + [
                "ps",
                "--all",
                "--filter",
                "label=com.docker.compose.service",
                "--format",
                "{{.ID}}",
            ],
            timeout=20,
        ).stdout
        container_ids = output.split()
        if not container_ids:
            return []
        inspected = self.runner.run(self.config.inner_docker + ["inspect", *container_ids], timeout=30).stdout
        try:
            data = json.loads(inspected)
        except json.JSONDecodeError as error:
            raise CommandError(f"Unable to parse Docker container inspection: {error}") from error
        return data if isinstance(data, list) else []


class LogCollector:
    def __init__(self, config: SupervisorConfig, runner: CommandRunner) -> None:
        self.config = config
        self.runner = runner
        self.cursors: dict[str, str] = {}
        self.rules = self._load_rules()

    def collect(self) -> LogBatch:
        scan_until_ns = time.time_ns()
        scan_until = self._docker_timestamp(scan_until_ns)
        initial_scan_since = self._docker_timestamp(scan_until_ns - INITIAL_LOG_LOOKBACK_SECONDS * 1_000_000_000)
        services = self._services()
        patterns_by_service: dict[str, list[tuple[str, re.Pattern[str]]]] = {}
        for service in services:
            patterns: dict[str, re.Pattern[str]] = {}
            for service_pattern, log_patterns in self.rules:
                if service_pattern.search(service):
                    patterns.update({pattern.pattern: pattern for pattern in log_patterns})
            if patterns:
                patterns_by_service[service] = list(patterns.items())

        inventory = self.runner.run(
            self.config.inner_docker
            + [
                "ps",
                "--filter",
                "label=com.docker.compose.service",
                "--format",
                '{{.ID}}|{{.Label "com.docker.compose.service"}}',
            ],
            timeout=20,
        ).stdout
        container_ids: dict[str, list[str]] = defaultdict(list)
        for line in inventory.splitlines():
            container_id, separator, service = line.partition("|")
            if separator and container_id and service:
                container_ids[service].append(container_id)

        observations: list[LogObservation] = []
        with ThreadPoolExecutor(max_workers=MAX_LOG_COLLECTORS) as executor:
            futures = {
                executor.submit(
                    self._collect_service,
                    service,
                    container_ids.get(service, []),
                    patterns,
                    self.cursors.get(service, initial_scan_since),
                    scan_until,
                ): service
                for service, patterns in patterns_by_service.items()
            }
            for future in as_completed(futures):
                service = futures[future]
                try:
                    observation = future.result()
                except Exception as error:  # keep one service from aborting the pass
                    LOG.warning("Log collection failed for %s: %s", service, error)
                    observation = LogObservation(service=service, available=False)
                if observation.available:
                    self.cursors[service] = scan_until
                observations.append(observation)
        return LogBatch(tuple(observations))

    def _collect_service(
        self,
        service: str,
        container_ids: list[str],
        patterns: list[tuple[str, re.Pattern[str]]],
        scan_since: str,
        scan_until: str,
    ) -> LogObservation:
        if not container_ids:
            return LogObservation(service=service, available=False)
        matches: list[LogMatch] = []
        for container_id in container_ids:
            completed = self.runner.run(
                self.config.inner_docker
                + [
                    "logs",
                    "--since",
                    scan_since,
                    "--until",
                    scan_until,
                    container_id,
                ],
                timeout=30,
            )
            lines = (completed.stdout + completed.stderr).splitlines()
            for pattern_text, pattern in patterns:
                count = sum(1 for line in lines if pattern.search(line))
                if count:
                    matches.append(LogMatch(container_id, pattern_text, count))
        return LogObservation(service=service, matches=tuple(matches))

    def _services(self) -> list[str]:
        output = self.runner.run(self.config.compose + ["config", "--services"], timeout=20).stdout
        services = [service for service in output.splitlines() if service]
        if not services:
            raise CommandError("Compose returned no services for log monitoring")
        return services

    @staticmethod
    def _docker_timestamp(timestamp_ns: int) -> str:
        seconds, nanoseconds = divmod(timestamp_ns, 1_000_000_000)
        return f"{seconds}.{nanoseconds:09d}"

    def _load_rules(self) -> list[tuple[re.Pattern[str], list[re.Pattern[str]]]]:
        with self.config.log_config_file.open(encoding="utf-8") as config_file:
            raw_rules = json.load(config_file)
        return [
            (
                re.compile(rule["service"]),
                [re.compile(pattern) for pattern in rule.get("patterns", [])],
            )
            for rule in raw_rules
        ]


class RecoveryHandler:
    def __init__(self, config: SupervisorConfig, runner: CommandRunner) -> None:
        self.config = config
        self.runner = runner

    def recover(self, request: RecoveryRequest) -> None:
        if request.kind == "dind":
            self._recover_dind()
        elif request.kind == "service":
            self._recover_service(request.service)

    def _recover_service(self, service: str) -> None:
        LOG.warning("Restarting service %s", service)
        try:
            self.runner.run(self.config.compose + ["restart", service], timeout=180)
        except CommandError as restart_error:
            LOG.warning("Direct restart failed for %s: %s; attempting recreation", service, restart_error)
            try:
                self.runner.run(
                    self.config.compose + ["up", "--detach", "--no-deps", service],
                    timeout=180,
                )
            except CommandError as recreate_error:
                LOG.error("Failed to recover %s: %s", service, recreate_error)

    def _recover_dind(self) -> None:
        LOG.warning("Recreating the unresponsive DinD container")
        with suppress(CommandError):
            self.runner.run(["docker", "rm", "--force", self.config.dind_name], timeout=30)
        try:
            self.config.dind_socket.unlink(missing_ok=True)
            self.runner.run_shell(self.config.dind_run_command, timeout=180)
            self.runner.run_shell(self.config.dind_network_connect_command, timeout=30)
            self._wait_for_dind()
            workdir = str(self.config.data_path / "self_hosted")
            exec_prefix = ["docker", "exec", f"--workdir={workdir}", self.config.dind_name]
            self.runner.run(
                exec_prefix + ["sh", "-c", "apk add --no-cache bash coreutils cgroup-tools git >/dev/null"],
                timeout=180,
            )
            self.runner.run(exec_prefix + ["cgcreate", "-g", "cpu:/sentry-backend-services"])
            self.runner.run(
                exec_prefix + ["cgset", "-r", f"cpu.weight={self.config.dind_cpu_shares}", "/sentry-backend-services"]
            )
            self.runner.run(
                exec_prefix
                + [
                    "cgset",
                    "-r",
                    f"cpu.max={self.config.services_cpu_quota} {self.config.cpu_period}",
                    "/sentry-backend-services",
                ]
            )
            self.runner.run(self.config.compose + ["up", "--detach", "--remove-orphans"], timeout=300)
        except (CommandError, OSError) as error:
            LOG.error("DinD recovery did not complete: %s", error)

    def _wait_for_dind(self) -> None:
        for _ in range(30):
            try:
                self.runner.run(
                    ["docker", "exec", self.config.dind_name, "docker", "info"],
                    timeout=DIND_PROBE_TIMEOUT_SECONDS,
                )
                return
            except CommandError:
                time.sleep(2)
        raise CommandError("Recreated DinD container did not become ready")


class Supervisor:
    def __init__(self, config: SupervisorConfig) -> None:
        self.config = config
        self.runner = CommandRunner()
        self.coordinator = IncidentCoordinator()
        self.notifier = NotificationHandler(config)
        self.recovery = RecoveryHandler(config, self.runner)
        self.observations: queue.Queue[HealthBatch | LogBatch] = queue.Queue()
        self.stop_event = threading.Event()

    def run(self) -> int:
        collectors = [
            threading.Thread(
                target=self._collector_loop,
                args=("health", HealthCollector(self.config, self.runner).collect, HEALTH_INTERVAL_SECONDS),
                daemon=True,
            )
        ]
        if self.config.enable_log_monitor:
            collectors.append(
                threading.Thread(
                    target=self._collector_loop,
                    args=("logs", LogCollector(self.config, self.runner).collect, LOG_INTERVAL_SECONDS),
                    daemon=True,
                )
            )
        for collector in collectors:
            collector.start()
        self.notifier.start()

        LOG.info("Supervisor started with unified per-service incident coordination")
        try:
            while not self.stop_event.is_set():
                try:
                    batch = self.observations.get(timeout=1)
                except queue.Empty:
                    continue
                self._process_batch(batch)
        except Exception:
            LOG.exception("Supervisor encountered an unrecoverable internal error")
            return 1
        finally:
            self.stop_event.set()
            for collector in collectors:
                collector.join(timeout=2)
            self.notifier.close()
        return 0

    def stop(self, _signum: int, _frame: object) -> None:
        self.stop_event.set()

    def _collector_loop(self, name: str, collect: Callable[[], HealthBatch | LogBatch], interval: int) -> None:
        while not self.stop_event.is_set():
            started = time.monotonic()
            try:
                batch = collect()
                self.observations.put(batch)
                LOG.info("%s collection completed in %.1fs", name.capitalize(), time.monotonic() - started)
            except Exception as error:
                LOG.warning("%s collection failed; it will be retried: %s", name.capitalize(), error)
            self.stop_event.wait(interval)

    def _process_batch(self, batch: HealthBatch | LogBatch) -> None:
        recoveries: list[RecoveryRequest] = []
        notifications: list[NotificationEvent] = []
        if isinstance(batch, HealthBatch):
            for observation in batch.observations:
                new_recoveries, new_notifications = self.coordinator.observe_health(observation, now=batch.collected_at)
                recoveries.extend(new_recoveries)
                notifications.extend(new_notifications)
        else:
            for observation in batch.observations:
                notifications.extend(self.coordinator.observe_logs(observation))

        for event in notifications:
            self.notifier.enqueue(event)
        for request in recoveries:
            self.recovery.recover(request)
            self.coordinator.defer_health_evaluation(request.service, time.time() + SERVICE_RECHECK_SECONDS)


def configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="[sentry-supervisor.py] [%(asctime)s]: %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def main() -> int:
    configure_logging()
    supervisor = Supervisor(SupervisorConfig.from_environment())
    signal.signal(signal.SIGTERM, supervisor.stop)
    signal.signal(signal.SIGINT, supervisor.stop)
    return supervisor.run()


if __name__ == "__main__":
    raise SystemExit(main())
