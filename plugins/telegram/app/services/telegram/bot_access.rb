module Telegram
  # How the rest of the plugin reaches the bot token. Everything goes through
  # the Connected Accounts broker's system-invocation path, using this
  # plugin's registered service identity and the instance-owned `telegram_bot`
  # account. No other code in the plugin reads or holds the token.
  #
  # The one exception is the migration window: while a token still lives in
  # the legacy application setting *and no instance account exists yet*, calls
  # use it so delivery keeps working if the copy has not succeeded
  # (Telegram::TokenMigration). Once an account exists the setting is never
  # read again, even if the account is later disconnected.
  #
  # Each call is one lease, audited with the purpose below. Long-polling makes
  # that one audit row per getUpdates call; Connected Accounts' retention
  # policy bounds how long those rows are kept.
  module BotAccess
    class NotConfigured < StandardError; end

    TARGET = { url: Telegram::Provider::API_ORIGIN }.freeze
    HANDLE_CACHE_TTL = 10.minutes

    module_function

    def configured?
      if connected_account
        TokenMigration.retire_legacy_once
        return true
      end

      TokenMigration.call_if_due
      connected_account.present? || legacy_pending?
    end

    def get_updates(offset:, timeout: 25)
      perform("get_updates", purpose: "poll Telegram for new messages", input: { offset: offset, timeout: timeout })
    end

    def send_message(chat_id:, text:, parse_mode: nil)
      perform("send_message", purpose: "deliver a Telegram message", input: { chat_id: chat_id, text: text, parse_mode: parse_mode })
    end

    # The bot's @handle (without the @) as resolved by Telegram, cached
    # briefly. nil when the bot is unreachable or not configured.
    def handle
      account = connected_account
      return Rails.cache.fetch("telegram:bot_handle:#{account.credential_store_credential_id}", expires_in: HANDLE_CACHE_TTL) { resolve_handle } if account

      legacy_pending? ? Syrus::Host::AppSetting.telegram_bot_handle : nil
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

      raise NotConfigured, "Telegram bot account is not connected" unless legacy_pending?

      Provider.perform(TokenMigration.legacy_token, Provider::OPERATIONS.fetch(operation), input)
    end

    def brokered(account, operation, purpose, input)
      Provider.with_system_access(
        identity: Provider::IDENTITY, account: account, scopes: [ Provider::SCOPE ],
        purpose: purpose, target: TARGET, input: input.merge(operation: operation)
      )
    end

    def resolve_handle
      perform("get_me", purpose: "resolve the Telegram bot handle", input: {})[:username]
    rescue StandardError => error
      Rails.logger.warn("Telegram::BotAccess: could not resolve the bot handle (#{error.class})")
      nil
    end
  end
end
