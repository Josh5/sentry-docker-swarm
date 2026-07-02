# Docker Swarm Stack Releases

## Setup Portainer

### Create a custom network

Before adding the stack, create a custom overlay network called `sentry-private`. See below screenshot for details.
![Portainer Custom Network](./docs/images/sentry-private-network.png)

### Adding a stack

In the environment, add a new stack following these steps:

1. Name the stack according the the docker-compose YAML file name in this repo.
1. Configure the stack to pull from a git repository.
1. Enter in the details for this repo.
   - Repository URL: `<url>`
   - Repository reference: `refs/heads/<branch>`
1. Enter the name of the docker-compose YAML file.
1. Enable GitOps updates.
1. Configure Polling updates with an interval of `5m` (or whatever value you like).
1. Configure Environment Variables. These are notated in the header of the docker-compose YAML file.

## Sentry Config Vars

These variables configure the upstream `getsentry/self-hosted` stack that the manager downloads and runs. They are distinct from manager-only variables such as Docker version selection, log monitoring controls, or DIND resource limits.

Where practical, the defaults here are intended to align with upstream self-hosted behavior. When a variable is left unset in this project, the manager generally preserves the upstream self-hosted default by copying upstream `.env` into `.env.custom` first and only writing overrides when a value is explicitly provided.

References:

- Upstream self-hosted releases: <https://github.com/getsentry/self-hosted/releases>
- Upstream self-hosted docs: <https://develop.sentry.dev/self-hosted/>

### Core Settings

`SENTRY_BEACON_DISABLED`

- Default: `true` in this project.
- Controls Sentry self-hosted telemetry beacon behavior.
- This project writes `SENTRY_BEACON=False` into `sentry.conf.py` when enabled.

`SENTRY_SECRET_KEY`

- Required.
- Sets Sentry’s system secret key.
- Keep this stable across restarts and upgrades.
- Upstream docs: <https://develop.sentry.dev/self-hosted/configuration/>

`SENTRY_URL_PREFIX`

- Required.
- Public base URL for the Sentry installation, for example `https://sentry.example.com`.
- Used for generated links, auth flows, and external integrations.

`SENTRY_COMPOSE_PROFILES`

- Default: `feature-complete`
- Upstream supports at least `feature-complete` and `errors-only`.
- `errors-only` is a major footprint reduction lever if you do not need traces, replays, profiling, uptime, and related services.
- Upstream docs: <https://develop.sentry.dev/self-hosted/optional-features/errors-only/>

`SENTRY_INITIAL_ADMIN_EMAIL`

- Used by this project when creating the initial admin account.

### Database Settings

`SENTRY_CUSTOM_DB_CONFIG`

- Default: `false`
- Enables writing custom Postgres connection settings into `sentry.conf.py`.
- Leave this `false` when using the bundled upstream Postgres.

`SENTRY_DB_NAME`

- Default upstream-style value: `postgres`
- Database name for custom DB deployments.

`SENTRY_DB_USER`

- Default upstream-style value: `postgres`
- Database user for custom DB deployments.

`SENTRY_DB_PASSWORD`

- Database password for custom DB deployments.

`SENTRY_POSTGRES_HOST`

- Default upstream-style value: `postgres`
- Hostname for custom DB deployments.

`SENTRY_POSTGRES_PORT`

- Default upstream-style value: `5432`
- Port for custom DB deployments.

### Event Retention And Storage

`SENTRY_EVENT_RETENTION_DAYS`

- Upstream default: `90`
- Controls how long Sentry retains event data.
- This also influences upstream SeaweedFS lifecycle policy setup for the nodestore bucket.
- Upstream nodestore bootstrap script sets SeaweedFS lifecycle based on this value.
- Related upstream issue for SeaweedFS retention behavior: <https://github.com/getsentry/self-hosted/issues/4353>

`FORCE_NODESTORE_READ_THROUGH`

- Default: `false`
- Project-specific compatibility override for nodestore migration/read behavior.
- Only use if you know you need read-through enabled after nodestore migration work.
- Related upstream issue: <https://github.com/getsentry/self-hosted/issues/3960>

`FORCE_NODESTORE_DELETE_THROUGH`

- Default: `false`
- Project-specific compatibility override paired with `FORCE_NODESTORE_READ_THROUGH`.
- Only use when migrating or reconciling nodestore behavior and you understand the impact.

`SENTRY_FILESTORE_BACKEND_S3_BUCKET`

- Optional.
- Enables custom S3 filestore backend configuration in `config.yml`.
- Leave unset to keep the upstream default filestore behavior.

### Worker And Queue Processing

`SENTRY_TASKWORKER_CONCURRENCY`

- Upstream default: `4`
- Controls the concurrency of the main Sentry taskworker process.
- This is one of the safest first throughput knobs to raise if async task backlog is the actual bottleneck.
- Higher values increase CPU and memory pressure.
- Used by current upstream self-hosted releases in the taskworker command.

`LAUNCHPAD_TASKWORKER_CONCURRENCY`

- Upstream default: `4`
- Controls concurrency of the `launchpad-taskworker` container introduced in newer self-hosted releases.
- Only matters on releases that include Launchpad support.
- For `26.5.0` and higher, this applies to the `launchpad-taskworker` container added during the hard-stop transition.
- Related upstream release notes: <https://github.com/getsentry/self-hosted/releases/tag/26.5.0>, <https://github.com/getsentry/self-hosted/releases/tag/26.6.0>

`LAUNCHPAD_RPC_SHARED_SECRET`

- Upstream bundled `.env` default: `supersecret`
- This project strongly recommends overriding it with a unique high-entropy secret for real deployments.
- This is a security setting, not a throughput setting.
- For `26.5.0` and higher, this is relevant because Launchpad/taskbroker RPC wiring was added to self-hosted.
- Related upstream release notes: <https://github.com/getsentry/self-hosted/releases/tag/26.5.0>, <https://github.com/getsentry/self-hosted/releases/tag/26.6.0>

`SENTRY_KAFKA_MAX_POLL_INTERVAL_MS`

- Upstream effective compose default in releases that expose this setting: `300000`
- Used across many Sentry and Snuba Kafka consumers.
- This is mainly a consumer stability knob, not a raw throughput knob. Raise it when long-processing consumers are being evicted with `MAXPOLL`-style behavior.
- For `26.6.0` and higher, upstream wires this through many Sentry and Snuba consumer commands.
- Related upstream change: <https://github.com/getsentry/self-hosted/pull/4376>

### Kafka Retention And Disk Control

These are useful first-class overrides because Kafka disk growth is one of the more common self-hosted operational concerns. They map to upstream Kafka broker environment variables consumed by the bundled Kafka container.

Current relevance notes:

- The operational problem described in older Kafka-disk threads is still relevant on newer self-hosted releases, including the `26.x` line, because the bundled stack still uses Kafka heavily and recent releases still document Kafka retention tuning as a valid operator tool.
- The exact numbers from old discussions should be treated as examples, not as authoritative upstream defaults.
- Current upstream troubleshooting guidance still points operators at Kafka retention settings when reducing disk usage and states that self-hosted defaults to 24-hour Kafka retention.

Useful references:

- Upstream troubleshooting page, including retention, lag, offset reset, and partition scaling guidance:
  <https://develop.sentry.dev/self-hosted/troubleshooting/kafka/>
- Kafka disk growth report from a more recent self-hosted release (`24.10.0`), useful as current symptom context:
  <https://github.com/getsentry/self-hosted/issues/3389>
- Kafka volume growth / disk exhaustion discussion from the `25.x` era:
  <https://github.com/getsentry/self-hosted/issues/3691>
- Older Sentry forum thread on restricting Kafka disk usage:
  <https://forum.sentry.io/t/restrict-kafka-disk-usage/9838>
- Another Sentry forum post referenced by upstream troubleshooting:
  <https://forum.sentry.io/t/sentry-disk-cleanup-kafka/11337/2?u=byk>
- General Kafka retention mechanics reference:
  <https://iv-m.github.io/articles/kafka-limit-disk-space/>

`KAFKA_LOG_RETENTION_HOURS`

- Recommended starting point: `24`
- Sets time-based Kafka log retention.
- This aligns with upstream self-hosted troubleshooting guidance, which says self-hosted uses a retention time of 24 hours by default.
- Kafka reference: <https://docs.confluent.io/platform/current/installation/configuration/broker-configs.html#log-retention-hours>

`KAFKA_LOG_RETENTION_BYTES`

- No single universally correct value.
- Conservative recommended starting point for this project: `1073741824` (`1 GiB`).
- Useful when you want tighter control over Kafka disk growth.
- This setting can authorize much more disk use than expected because Kafka storage multiplies across logs rather than acting like a single overall stack cap.
- Kafka reference: <https://docs.confluent.io/platform/current/installation/configuration/broker-configs.html#log-retention-bytes>

`KAFKA_LOG_SEGMENT_BYTES`

- Recommended starting point: `524288000`
- Controls segment size before Kafka rolls to a new segment.
- This affects cleanup granularity and how quickly retention policies can reclaim space.
- Kafka reference: <https://docs.confluent.io/platform/current/installation/configuration/broker-configs.html#log-segment-bytes>

`KAFKA_LOG_RETENTION_CHECK_INTERVAL_MS`

- Recommended starting point: `300000`
- Controls how often Kafka checks whether segments should be deleted due to retention rules.
- Kafka reference: <https://docs.confluent.io/platform/current/installation/configuration/broker-configs.html#log-retention-check-interval-ms>

`KAFKA_LOG_SEGMENT_DELETE_DELAY_MS`

- Recommended starting point: `60000`
- Delay before deleting old log segments after they become eligible for deletion.
- Kafka reference: <https://docs.confluent.io/platform/current/installation/configuration/broker-configs.html#log-segment-delete-delay-ms>

`KAFKA_LOG_CLEANER_ENABLE`

- Default: `true`
- Useful as part of an aggressive “keep Kafka disk bounded” posture.
- This has appeared in both community guidance and upstream troubleshooting examples for reducing Kafka disk usage.
- Upstream troubleshooting example:
  <https://develop.sentry.dev/self-hosted/troubleshooting/kafka/>

`KAFKA_LOG_CLEANUP_POLICY`

- Default: `delete`
- Pairs naturally with retention-based disk control.
- Useful when you want Kafka to behave like a bounded buffer rather than a long-lived retained log for self-hosted Sentry workloads.
- Upstream troubleshooting example:
  <https://develop.sentry.dev/self-hosted/troubleshooting/kafka/>

### Mail And User Verification

`SENTRY_CUSTOM_MAIL_SERVER_CONFIG`

- Default: `false`
- Enables writing SMTP settings directly into `config.yml`.

`SENTRY_EMAIL_HOST`

- SMTP host when `SENTRY_CUSTOM_MAIL_SERVER_CONFIG=true`.

`SENTRY_EMAIL_PORT`

- SMTP port when `SENTRY_CUSTOM_MAIL_SERVER_CONFIG=true`.

`SENTRY_EMAIL_USER`

- SMTP username when `SENTRY_CUSTOM_MAIL_SERVER_CONFIG=true`.

`SENTRY_EMAIL_PASSWORD`

- SMTP password when `SENTRY_CUSTOM_MAIL_SERVER_CONFIG=true`.

`SENTRY_EMAIL_USE_TLS`

- SMTP STARTTLS toggle when `SENTRY_CUSTOM_MAIL_SERVER_CONFIG=true`.

`SENTRY_EMAIL_USE_SSL`

- SMTP SSL toggle when `SENTRY_CUSTOM_MAIL_SERVER_CONFIG=true`.

`SENTRY_SERVER_EMAIL`

- Sender/from address written into Sentry config.

`SENTRY_MAIL_HOST`

- Mail namespace / hostname used by upstream mail settings when not using full custom SMTP config.
- For `26.6.0` and higher, working outbound mail is called out more explicitly upstream because user email verification flows matter operationally.
- Review the target release notes and upstream config examples for your chosen version when planning mail behavior during upgrades.

### GitHub Integration

`SENTRY_GITHUB_LOGIN_EXTENDED_PERMISSIONS`

- Default: `repo`
- Sets extended GitHub login permissions for GitHub integration behavior.

`SENTRY_GITHUB_APP_ID`

- GitHub App ID for GitHub App integration.

`SENTRY_GITHUB_APP_NAME`

- GitHub App name.

`SENTRY_GITHUB_APP_WEBHOOK_SECRET`

- Optional GitHub App webhook secret.

`SENTRY_GITHUB_APP_CLIENT_ID`

- GitHub App client ID.

`SENTRY_GITHUB_APP_CLIENT_SECRET`

- GitHub App client secret.

`SENTRY_GITHUB_APP_PRIVATE_KEY`

- GitHub App private key material.

### Logging And Advanced Escape Hatches

`SENTRY_LOG_FORMAT`

- Default: `human`
- Accepted values:
  - `machine` => JSON-style logs
  - `human` => human-readable logs
- Controls upstream Sentry logging format in `.env`.
- Upstream logging format reference:
  <https://github.com/getsentry/sentry/blob/26.6.0/src/sentry/logging/README.rst#formats>

`SENTRY_CONF_CUSTOM`

- Appends arbitrary extra Python config to generated `sentry.conf.py`.
- Use for advanced features not promoted to first-class vars in this project.

`SENTRY_ENV_CUSTOM`

- Appends arbitrary extra `.env` lines to upstream `.env.custom`.
- Use for advanced upstream env settings that are intentionally not first-class here.
- This remains the fallback for less common Kafka settings, experimental tuning, or one-off upstream flags.
