# Helpers for specs that exercise the Telegram bot token through the Connected
# Accounts broker. Both plugins depend on connected_accounts (which needs
# credential_store), so every spec that enables the plugin enables those too.
module TelegramBotAccountHelpers
  PLUGIN_CHAIN = %w[credential_store connected_accounts telegram].freeze

  def enable_telegram_plugin!
    PLUGIN_CHAIN.each { |name| PluginRecord.find_by!(name: name).update!(enabled: true) }
  end

  # Connects an instance-owned telegram_bot account holding +token+ without
  # touching the network unless +stub_http+ is false (then the caller stubs
  # the HTTP requests with WebMock).
  def connect_telegram_bot!(token: "telegram-bot-token", label: "Syrus bot", stub_http: true)
    enable_telegram_plugin!
    admin = User.where(global_role: "admin").first || Factories.user(global_role: "admin")
    if stub_http
      # Stub the HTTP client rather than the provider: the registry re-checks
      # the provider's method signatures, which an rspec double would break.
      allow_any_instance_of(Telegram::Client).to receive(:get_me).and_return("username" => label, "first_name" => label)
    end
    ConnectedAccounts::TokenBroker.connect!(provider: Telegram::Provider::KEY, token: token, label: label, admin: admin)
  end
end

RSpec.configure { |config| config.include TelegramBotAccountHelpers }
