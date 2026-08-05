module ChatSpeechToText
  module Telemetry
    module_function

    def log(event, **fields)
      event_name = "chat_speech_to_text.#{event}"
      payload = safe_fields(fields)
      ActiveSupport::Notifications.instrument(event_name, payload)
      Rails.logger.info({ event: event_name }.merge(payload).to_json)
    rescue StandardError
      nil
    end

    def provider_name(provider)
      provider.class.name.demodulize.underscore
    end

    def duration_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def safe_error(error)
      {
        error_class: error.class.name,
        error_code: error.respond_to?(:code) ? error.code.to_s : nil
      }.compact
    end

    def safe_fields(fields)
      fields.each_with_object({}) do |(key, value), safe|
        next if value.nil?

        safe[key] = value.is_a?(Hash) ? safe_fields(value) : value
      end
    end
  end
end
