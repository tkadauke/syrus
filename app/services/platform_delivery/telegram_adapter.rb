module PlatformDelivery
  class TelegramAdapter < BaseAdapter
    TELEGRAM_MAX_CHARS = 4096

    def deliver(message:, platform_identity:)
      text = message.extract_text_from_content
      return if text.blank?

      split_for_telegram(text).each do |chunk|
        TelegramClient.new.send_message(
          chat_id: platform_identity.external_id,
          text: chunk
        )
      end
    rescue => e
      Rails.logger.error("TelegramAdapter#deliver: #{e}")
    end

    private

    def split_for_telegram(text)
      return [text] if text.length <= TELEGRAM_MAX_CHARS

      chunks = []
      remaining = text
      while remaining.length > TELEGRAM_MAX_CHARS
        chunk = remaining[0, TELEGRAM_MAX_CHARS]
        newline_index = chunk.rindex("\n")
        split_at = newline_index.to_i.positive? ? newline_index : TELEGRAM_MAX_CHARS
        chunks << remaining[0, split_at]
        remaining = remaining[split_at..].lstrip
      end
      chunks << remaining unless remaining.empty?
      chunks
    end
  end
end
