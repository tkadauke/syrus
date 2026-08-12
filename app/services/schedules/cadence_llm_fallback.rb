module Schedules
  # Structured-intent-only LLM fallback for cadence text that deterministic
  # parsing in RecurringSchedule could not handle (typos, phrasing variants).
  # Never returns anything executable — only a plain hash of the same shape
  # RecurringSchedule#parse_structured_intent already validates/canonicalizes
  # deterministically. Fails closed: missing credentials, low confidence, or
  # an ambiguous/malformed response all come back unusable rather than
  # guessing a schedule.
  class CadenceLlmFallback
    Result = Data.define(:usable?, :structured_intent, :error)

    RESPONSE_SCHEMA = {
      type: "OBJECT",
      properties: {
        frequency: { type: "STRING", enum: %w[ HOURLY DAILY WEEKLY MONTHLY YEARLY UNKNOWN ] },
        day: { type: "STRING" },
        month: { type: "INTEGER" },
        month_day: { type: "INTEGER" },
        hour: { type: "INTEGER" },
        minute: { type: "INTEGER" },
        confidence: { type: "STRING", enum: %w[ high low ] },
        ambiguous: { type: "BOOLEAN" }
      },
      required: %w[ frequency confidence ambiguous ]
    }.freeze

    class << self
      # Test seam — specs stub this instead of hitting a real Gemini
      # endpoint. Production default builds a per-user Gemini client from
      # their configured API key and fails closed (nil) when absent.
      attr_writer :client_factory

      def client_factory
        @client_factory ||= ->(user) { user&.gemini_api_key.present? ? Gemini::Client.new(api_key: user.gemini_api_key) : nil }
      end

      def call(text, user:)
        new(text, user: user).call
      end
    end

    def initialize(text, user:, client_factory: self.class.client_factory)
      @text = text.to_s
      @user = user
      @client_factory = client_factory
    end

    def call
      return unusable("Schedule input is required") if @text.blank?

      client = @client_factory.call(@user)
      return unusable("No AI scheduling assistant is configured for this account") unless client

      intent = normalize(client.generate_text(prompt: prompt, response_schema: RESPONSE_SCHEMA))
      return unusable("The assistant could not confidently interpret this schedule") unless usable_intent?(intent)

      Result.new(usable?: true, structured_intent: intent, error: nil)
    rescue Gemini::Client::Error => e
      unusable("Could not reach the scheduling assistant: #{e.message}")
    end

    private

    def unusable(message)
      Result.new(usable?: false, structured_intent: nil, error: message)
    end

    def usable_intent?(intent)
      return false if intent[:confidence] != "high"
      return false if intent[:ambiguous]
      return false if intent[:frequency].blank? || intent[:frequency] == "UNKNOWN"
      return false if intent[:hour].nil?

      true
    end

    def normalize(response)
      values = response.to_h.transform_keys(&:to_s)
      {
        frequency: values["frequency"].to_s.upcase.presence,
        day: values["day"].presence,
        month: values["month"],
        month_day: values["month_day"],
        hour: values["hour"],
        minute: values["minute"] || 0,
        confidence: values["confidence"].to_s.downcase.presence,
        ambiguous: ActiveModel::Type::Boolean.new.cast(values["ambiguous"])
      }
    end

    def prompt
      <<~PROMPT
        Interpret the following recurring-schedule request as UTC cadence intent. The text may
        contain typos or unusual phrasing. Respond only with the structured fields defined by the
        response schema — never a cron expression or free-form explanation.

        Request: #{@text.inspect}

        Rules:
        - frequency must be one of HOURLY, DAILY, WEEKLY, MONTHLY, YEARLY, or UNKNOWN if you cannot tell.
        - day is the English weekday name (e.g. "monday"), required when frequency is WEEKLY.
        - month (1-12) is required when frequency is YEARLY.
        - month_day (1-31) is required when frequency is MONTHLY or YEARLY.
        - hour (0-23) and minute (0-59) are the UTC clock time the request describes.
        - Set confidence to "low" and ambiguous to true whenever the request is unclear, missing a
          time of day, or could plausibly mean more than one schedule. Never guess a time or day.
      PROMPT
    end
  end
end
