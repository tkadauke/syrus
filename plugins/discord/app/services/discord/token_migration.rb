module Discord
  # Moves a bot token from the legacy application setting onto the
  # instance-owned `discord_bot` connected account.
  #
  # Idempotent and safe to run at any time; it is attempted lazily by
  # Discord::BotAccess.configured? (at most every RETRY_INTERVAL per process)
  # so it needs no deploy-time step and retries after a transient failure.
  #
  #   1. No legacy token: nothing to do.
  #   2. No account yet: connect the token through the broker (which validates
  #      it against Discord first), then verify the account end to end with a
  #      brokered validation call. If verification fails the new account is
  #      rolled back, so delivery keeps using the legacy token.
  #   3. Only after the account is verified is the legacy value cleared.
  #      Leaving a second live copy would defeat the point: rotating or
  #      disconnecting the account would leave a still-valid token in settings
  #      that nothing audits. The token is not lost; it now lives encrypted in
  #      Credential Store.
  #   4. An account already exists (a previous run, or an operator connected
  #      one): a leftover legacy value is cleared once the account verifies.
  module TokenMigration
    RETRY_INTERVAL = 10.minutes
    PROVIDER = Discord::Provider::KEY

    module_function

    def legacy_token = Syrus::Host::AppSetting.discord_bot_token

    def call_if_due
      return unless legacy_token.present?
      return unless due?

      call
    end

    # => :nothing_to_migrate, :migrated, or :failed
    def call
      legacy = legacy_token
      return :nothing_to_migrate if legacy.blank?

      existing = ConnectedAccounts::TokenBroker.instance_account(PROVIDER)
      created = existing.nil?
      account = existing || connect(legacy)
      return fail_with("account could not be created") unless account
      return fail_with("account is not connected") unless account.connected?
      return rollback(account, created) unless verified?(account)

      Syrus::Host::AppSetting.current.update!(discord_bot_token: nil)
      :migrated
    rescue StandardError => error
      fail_with(error.message, secret: legacy)
    end

    # Once an account is connected the setting is dead weight: nothing reads
    # it, and a leftover value (a crash between copy and clear, or an operator
    # who connected an account by hand) is an unaudited second copy of the
    # secret. Wipe it without reading it, at most once per process.
    def retire_legacy_once
      return if @retired

      @retired = true
      Syrus::Host::AppSetting.where.not(discord_bot_token: nil).update_all(discord_bot_token: nil)
    end

    def reset!
      @last_attempt = nil
      @retired = false
    end

    def due?
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return false if @last_attempt && now - @last_attempt < RETRY_INTERVAL

      @last_attempt = now
      true
    end

    def connect(legacy)
      admin = Syrus::Host::UserRecord.where(global_role: "admin").order(:id).first
      return unless admin

      ConnectedAccounts::TokenBroker.connect!(provider: PROVIDER, token: legacy, label: nil, admin: admin)
    rescue ConnectedAccounts::TokenBroker::Error => error
      log(error.message, secret: legacy)
      nil
    end

    def verified?(account)
      result = BotAccess.brokered(account, "validate", "verify the migrated Discord bot account", {})
      result.to_h[:healthy] == true
    rescue StandardError => error
      log(error.message)
      false
    end

    def rollback(account, created)
      if created
        credential = account.credential_store_credential
        account.destroy!
        credential.update!(revoked_at: Time.current)
      end
      fail_with("account verification failed")
    end

    def fail_with(message, secret: nil)
      log(message, secret: secret)
      :failed
    end

    def log(message, secret: nil)
      safe = CredentialStore::Broker.redact(message.to_s, extra_secrets: [ secret ])
      Rails.logger.warn("Discord::TokenMigration: #{safe}; the legacy token stays in use until this succeeds")
    end
  end
end
