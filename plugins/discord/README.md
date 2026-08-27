# Discord

Discord adds a platform-delivery channel for Syrus chat. It links Discord users to Syrus accounts, listens for direct messages through the Gateway, and delivers chat replies back to Discord so operators can interact with Syrus away from the web UI.

The plugin is disabled by default because it requires Discord credentials and a running Gateway connection. Once configured, it behaves as another chat surface rather than a separate automation engine.

## What It Adds

- Discord account linking.
- Gateway-based direct-message ingestion.
- Message delivery from Syrus chats back to Discord.

## When To Enable

Enable Discord when operators should be able to use Syrus from Discord DMs. Keep it disabled on installations that use only the web app or desktop app.

## Operational Notes

This plugin depends on external Discord connectivity and credentials. It should be monitored like any other long-lived platform integration.
