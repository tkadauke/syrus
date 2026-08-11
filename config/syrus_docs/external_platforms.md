# External Platform Integrations

Syrus can receive messages from and deliver replies to external messaging platforms (Telegram, and future platforms). All integrations share a common inbound routing layer and an outbound delivery adapter registry. Core platforms (web, Telegram) are built into `PlatformDelivery::Registry`; additional platforms can be added by a plugin gem through the `:platform_delivery` extension point without a core code change.

## Architecture

**Inbound:** `InboundMessageRouter` maps an incoming external message to a Syrus user via `PlatformIdentity`, finds or creates a `ChatSession` for that user+platform pair, creates a user-role `ChatMessage`, and enqueues `ChatTurnJob` when the session's `trigger_policy` is `speak_when_spoken_to`.

**Outbound:** `ChatMessage` fires an `after_create_commit` hook for assistant-role messages in sessions with an `origin_platform`. For each session participant, Syrus looks up their `PlatformIdentity` for that platform and calls the matching `PlatformDelivery` adapter. Participants with no identity for the platform receive web delivery via ActionCable as usual.

**Polling:** Each platform integration runs as a subclass of `PlatformPollingJob`. The base class handles deduplication (at most one instance running), error logging, and self-re-enqueue on every cycle. Subclasses implement `configured?` (checks bot token/handle) and `poll_once` (does one long-poll cycle and calls `InboundMessageRouter` for each incoming message).

## PlatformIdentity

Users link external accounts in **Settings → Connected Platforms**. The link flow generates a short-lived token; the user sends that token to the bot; the bot calls the linking endpoint, which creates the `PlatformIdentity` row. `PlatformIdentity` stores the platform, `external_id` (stable bot-side user ID), `external_handle` (human-readable), and `linked_at`. `platform` is a plain string validated by inclusion against `PlatformIdentity.available_platforms` (the core `PLATFORMS` list plus every enabled plugin's registered `platform_key`), not a closed enum -- a plugin's platform is a valid value as soon as it registers. The linking-token endpoint and the Connected Platforms settings UI both enumerate `PlatformIdentity.available_platforms`, so a newly-registered (and enabled) plugin platform shows up automatically.

## Starting the poller

Platform polling jobs start automatically on application boot when their bot token is configured (`config/initializers/platform_polling.rb`). Core connectors (Telegram) start via `PlatformPollingJob.start_all!`, which walks its own inheritance-based registry of `PlatformPollingJob` subclasses. Plugin-provided connectors start via `PlatformDelivery::Registry.start_connectors!` instead, which iterates enabled `:platform_delivery` providers and starts each one's `.connector_job_class` -- so a disabled plugin's connector does not start. (`PlatformPollingJob.start_all!` excludes any subclass that is registered as a plugin's `connector_job_class`, so a plugin's job is never started twice and never started while its plugin is disabled.)

To start manually without a restart:

```
POST /api/v1/app/admin/platform_polling/start
```

Returns `{ "started": ["TelegramPollingJob", ...] }` with the names of jobs that were newly enqueued. Jobs already running are skipped. Requires admin authentication. This endpoint only covers `PlatformPollingJob.start_all!`'s (core) registry, not plugin connectors.

## Trigger policy

ChatSessions created via platform delivery use `trigger_policy: "speak_when_spoken_to"`: Syrus replies to every inbound user message. The policy is stored on the session and checked by `InboundMessageRouter`. Future policies (proactive, scheduled, etc.) can be added by extending `ChatSession::TRIGGER_POLICIES` and adding a handler in the router.

## Adding a new platform

**Core platform** (built directly into `app/`, like Telegram):

1. Create a `PlatformPollingJob` subclass (e.g. `SlackPollingJob`) that implements `configured?` and `poll_once`.
2. In `poll_once`, call `InboundMessageRouter.new(...).call` for each inbound message.
3. Create a `PlatformDelivery` adapter subclass and register it: `PlatformDelivery::Registry.register("slack", SlackAdapter)`.
4. Add the platform slug to `PlatformIdentity::PLATFORMS`.
5. Add any required `AppSetting` columns for the bot token/handle.

**Plugin platform** (a self-contained plugin gem, e.g. a future `plugins/discord/`):

1. Create an adapter class that includes `Syrus::Plugin::PlatformDelivery` and implements `.platform_key` (e.g. `"discord"`), `#deliver(message:, platform_identity:)`, and optionally `.connector_job_class` (a `PlatformPollingJob` subclass for the plugin's inbound listener, if it has one).
2. Register it from the plugin gem's engine initializer: `Syrus::PluginRegistry.register(name: "discord", version: "1.0.0", provides: { platform_delivery: Discord::PlatformAdapter })`.
3. `PlatformDelivery::Registry.for`, `PlatformIdentity.available_platforms`, and boot-time connector start all pick it up automatically, respecting the plugin's `PluginRecord` enable/disable state. No core code change needed.
4. If the platform needs custom linking instructions (bot handle, DM command, etc.), add a `PlatformIdentity::PlatformConfig` subclass for it -- otherwise it falls back to `PlatformIdentity::PlatformConfig::Unconfigured` (shows up in Settings, not connectable) until one exists.
