module Discord
  # How the rest of the plugin reaches the bot token. Everything goes through
  # the Connected Accounts broker's system-invocation path, using this
  # plugin's registered service identity and the instance-owned `discord_bot`
  # account. No other code in the plugin reads or holds the token.
  #
  # The one exception is the migration window: while a token still lives in
  # the legacy application setting *and no instance account exists yet*, calls
  # use it so delivery keeps working if the copy has not succeeded
  # (Discord::TokenMigration). Once an account exists the setting is never
  # read again, even if the account is later disconnected.
  module BotAccess
    class NotConfigured < StandardError; end

    TARGET = { url: Discord::Provider::API_ORIGIN }.freeze
    SEND_PURPOSE = "deliver a Discord direct message".freeze
    GATEWAY_PURPOSE = "hold the Discord Gateway connection".freeze

    module_function

    def configured?
      if connected_account
        TokenMigration.retire_legacy_once
        return true
      end

      TokenMigration.call_if_due
      connected_account.present? || legacy_pending?
    end

    def send_dm(user_id:, text:)
      perform("send_dm", purpose: SEND_PURPOSE, input: { user_id: user_id, text: text })
    end

    # Runs one Gateway session, yielding each DISPATCH event to `on_event`.
    # The session ends when it closes or when the account's credential is
    # rotated or revoked; the caller reconnects, which picks up the new token.
    # Returns a summary hash (see Discord::Provider.gateway_session).
    def gateway_session(on_event:)
      perform("gateway_session", purpose: GATEWAY_PURPOSE, input: { on_event: on_event, stale_check: stale_check })
    end

    def connected_account
      account = ConnectedAccounts::TokenBroker.instance_account(Provider::KEY)
      account if account&.connected?
    end

    # True only while an unmigrated legacy token is the sole credential.
    def legacy_pending?
      ConnectedAccounts::TokenBroker.instance_account(Provider::KEY).nil? && TokenMigration.legacy_token.present?
    end

    def perform(operation, purpose:, input:)
      account = connected_account
      return brokered(account, operation, purpose, input) if account

      raise NotConfigured, "Discord bot account is not connected" unless legacy_pending?

      Provider.perform(TokenMigration.legacy_token, Provider::OPERATIONS.fetch(operation), input)
    end

    def brokered(account, operation, purpose, input)
      Provider.with_system_access(
        identity: Provider::IDENTITY, account: account, scopes: [ Provider::SCOPE ],
        purpose: purpose, target: TARGET, input: input.merge(operation: operation)
      )
    end

    # Polled by the Gateway on each heartbeat. Becomes true as soon as the
    # credential the session started with is no longer the connected one.
    def stale_check
      started_with = connected_account&.credential_store_credential_id
      lambda do
        current = connected_account&.credential_store_credential_id
        started_with.nil? ? current.present? : current != started_with
      end
    end
  end
end
