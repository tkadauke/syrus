module Telegram
  # Connected-accounts provider for the Telegram bot token, and the only place
  # that token is ever handled in the clear.
  #
  # Telegram bot tokens are not OAuth: `authorization` describes token entry,
  # there is nothing to exchange or refresh, and the Bot API has no revocation
  # call for a token (it is reset through @BotFather), so `revoke` is a no-op.
  # `identity` resolves the bot's @handle via getMe and `validate` is the same
  # harmless authenticated call.
  #
  # Platform services reach the token only through `system_invoke`, called by
  # the broker with block-scoped access under a lease. Operations are fixed
  # here; callers send an operation name and plain-data input.
  class Provider
    extend ConnectedAccounts::SystemServiceProvider

    KEY = "telegram_bot".freeze
    IDENTITY = "telegram.platform".freeze
    SCOPE = "telegram.bot".freeze
    API_ORIGIN = "https://api.telegram.org/".freeze

    OPERATIONS = {
      "validate" => :check,
      "get_me" => :get_me,
      "get_updates" => :get_updates,
      "send_message" => :send_message
    }.freeze

    class << self
      def authorization(_context)
        { authorization_kind: "token", instructions: "Paste the bot token from @BotFather." }
      end

      def exchange_code(_context)
        raise ConnectedAccounts::Provider::PermanentError, "Telegram bot tokens do not use an authorization code"
      end

      # Bot tokens do not expire, so a refresh returns them unchanged.
      def refresh(context) = context.tokens

      def revoke(_context) = { revoked: true }

      def identity(context)
        { label: handle_label(Telegram::Client.new(token: context.access_token).get_me) }
      rescue Telegram::Client::Unauthorized => error
        raise ConnectedAccounts::Provider::PermanentError, error.message
      rescue Telegram::Client::Error, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, JSON::ParserError => error
        raise ConnectedAccounts::Provider::TransientError, error.class.name
      end

      def validate(context)
        identity(context)
        { healthy: true, message: "ok" }
      rescue ConnectedAccounts::Provider::PermanentError => error
        { healthy: false, message: error.message }
      end

      def system_invoke(context)
        operation = OPERATIONS[context.input[:operation].to_s]
        raise ArgumentError, "unsupported Telegram operation" unless operation

        context.access.with_token { |token| perform(token, operation, context.input) }
      end

      # Runs one operation with a token the caller holds for the call only.
      # Also the legacy path while a token has not been migrated yet.
      def perform(token, operation, input)
        public_send(operation, token, input)
      end

      def check(token, _input)
        validate(ConnectedAccounts::Provider::ValidateContext.new(access_token: token))
      end

      def get_me(token, _input)
        user = Telegram::Client.new(token: token).get_me
        { username: user["username"], first_name: user["first_name"] }
      end

      def get_updates(token, input)
        Telegram::Client.new(token: token).get_updates(offset: input.fetch(:offset), timeout: input.fetch(:timeout, 25))
      end

      def send_message(token, input)
        Telegram::Client.new(token: token).send_message(
          chat_id: input.fetch(:chat_id), text: input.fetch(:text), **input.slice(:parse_mode).compact
        )
      end

      private

      def handle_label(user)
        user["username"].present? ? "@#{user['username']}" : user["first_name"].to_s
      end
    end
  end
end
