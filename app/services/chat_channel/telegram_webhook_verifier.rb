require "openssl"
require "digest"

module ChatChannel
  class TelegramWebhookVerifier
    class << self
      def valid?(raw_body:, headers:)
        return false if raw_body.blank?

        secret = ChatChannel::Telegram.webhook_secret
        if secret.present?
          supplied = headers["HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN"] ||
                     headers["X-Telegram-Bot-Api-Secret-Token"]
          return secure_compare(secret, supplied)
        end

        bot_token = ChatChannel::Telegram.bot_token
        signature = headers["HTTP_X_TELEGRAM_BOT_API_SIGNATURE"] ||
                    headers["X-Telegram-Bot-Api-Signature"]
        return false if bot_token.blank? || signature.blank?

        # Telegram's HMAC schemes derive the signing secret from the bot
        # token. The webhook endpoint accepts this signature header for
        # deployments that put an HMAC-signing proxy in front of Rails; the
        # official Bot API secret-token header above remains the preferred
        # direct Telegram webhook check.
        key = Digest::SHA256.digest(bot_token)
        expected = OpenSSL::HMAC.hexdigest("SHA256", key, raw_body)
        secure_compare(expected, signature)
      end

      private

      def secure_compare(expected, supplied)
        return false if expected.blank? || supplied.blank?
        ActiveSupport::SecurityUtils.secure_compare(expected.to_s, supplied.to_s)
      rescue ArgumentError
        false
      end
    end
  end
end
