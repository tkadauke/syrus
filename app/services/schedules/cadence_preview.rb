module Schedules
  # Orchestrates the tiered cadence parser: deterministic parsing (cron or
  # simple natural language) first; only when that fails, and only for input
  # that isn't itself cron-shaped-but-invalid, hand the raw text to the LLM
  # fallback and re-run the SAME deterministic validate/canonicalize/explain
  # path on its structured intent. Callers that already have a
  # previously-resolved structured_intent (e.g. a save request that followed
  # a successful LLM-assisted preview) skip the LLM entirely.
  class CadencePreview
    def self.call(input:, structured_intent: nil, user: nil)
      new(input: input, structured_intent: structured_intent, user: user).call
    end

    def initialize(input:, structured_intent: nil, user: nil)
      @input = input
      @structured_intent = structured_intent
      @user = user
    end

    def call
      result = RecurringSchedule.preview(input: @input, structured_intent: @structured_intent)
      return result if result.valid?
      return result if @structured_intent.present?
      return result if RecurringSchedule.cron_shaped?(@input)

      fallback = CadenceLlmFallback.call(@input, user: @user)
      return result unless fallback.usable?

      RecurringSchedule.preview(input: @input, structured_intent: fallback.structured_intent)
    end
  end
end
