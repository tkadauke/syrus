require "bigdecimal"

module AgentPricing
  Price = Data.define(
    :input_per_million,
    :output_per_million,
    :cache_creation_input_per_million,
    :cache_read_input_per_million
  )

  DEFAULT_OPENAI_HIGH = Price.new(
    input_per_million: BigDecimal("5.00"),
    output_per_million: BigDecimal("30.00"),
    cache_creation_input_per_million: BigDecimal("5.00"),
    cache_read_input_per_million: BigDecimal("0.50")
  )

  class Base
    PROVIDERS = {
      "agy" => "AgentPricing::OpenAICompatible",
      "claude" => "AgentPricing::Claude",
      "codex" => "AgentPricing::OpenAICompatible",
      "muse" => "AgentPricing::OpenAICompatible"
    }.freeze

    def self.for(provider)
      PROVIDERS.fetch(provider.to_s, "AgentPricing::Null").constantize.new
    end

    def estimate(input_tokens:, output_tokens:, cache_creation_input_tokens: nil, cache_read_input_tokens: nil, model: nil)
      price = price_for(model)
      return if price.nil?
      return if [ input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens ].all?(&:blank?)

      (
        token_cost(input_tokens, price.input_per_million) +
        token_cost(output_tokens, price.output_per_million) +
        token_cost(cache_creation_input_tokens, price.cache_creation_input_per_million) +
        token_cost(cache_read_input_tokens, price.cache_read_input_per_million)
      ).round(6)
    end

    private

    def price_for(_model) = nil

    def token_cost(tokens, per_million)
      return BigDecimal("0") if tokens.blank? || per_million.blank?

      BigDecimal(tokens.to_s) * per_million / 1_000_000
    end
  end

  class Claude < Base
    SONNET_5 = Price.new(
      input_per_million: BigDecimal("2.00"),
      output_per_million: BigDecimal("10.00"),
      cache_creation_input_per_million: BigDecimal("2.50"),
      cache_read_input_per_million: BigDecimal("0.20")
    )
    SONNET_4 = Price.new(
      input_per_million: BigDecimal("3.00"),
      output_per_million: BigDecimal("15.00"),
      cache_creation_input_per_million: BigDecimal("3.75"),
      cache_read_input_per_million: BigDecimal("0.30")
    )
    OPUS_4 = Price.new(
      input_per_million: BigDecimal("15.00"),
      output_per_million: BigDecimal("75.00"),
      cache_creation_input_per_million: BigDecimal("18.75"),
      cache_read_input_per_million: BigDecimal("1.50")
    )
    HAIKU_4_5 = Price.new(
      input_per_million: BigDecimal("1.00"),
      output_per_million: BigDecimal("5.00"),
      cache_creation_input_per_million: BigDecimal("1.25"),
      cache_read_input_per_million: BigDecimal("0.10")
    )
    PRICE_MATCHERS = [
      [ /sonnet-5/, SONNET_5 ],
      [ /opus-4/, OPUS_4 ],
      [ /haiku-4-5/, HAIKU_4_5 ]
    ].freeze

    private

    def price_for(model)
      PRICE_MATCHERS.find { |pattern, _price| model.to_s.match?(pattern) }&.last || SONNET_4
    end
  end

  class OpenAICompatible < Base
    GPT_5 = Price.new(
      input_per_million: BigDecimal("1.25"),
      output_per_million: BigDecimal("10.00"),
      cache_creation_input_per_million: BigDecimal("1.25"),
      cache_read_input_per_million: BigDecimal("0.125")
    )
    GPT_5_CODEX = Price.new(
      input_per_million: BigDecimal("1.75"),
      output_per_million: BigDecimal("14.00"),
      cache_creation_input_per_million: BigDecimal("1.75"),
      cache_read_input_per_million: BigDecimal("0.175")
    )
    GPT_5_CODEX_MINI = Price.new(
      input_per_million: BigDecimal("0.25"),
      output_per_million: BigDecimal("2.00"),
      cache_creation_input_per_million: BigDecimal("0.25"),
      cache_read_input_per_million: BigDecimal("0.025")
    )
    PRICE_MATCHERS = [
      [ /codex-mini/, GPT_5_CODEX_MINI ],
      [ /codex/, GPT_5_CODEX ],
      [ /\Agpt-5/, GPT_5 ]
    ].freeze

    private

    def price_for(model)
      PRICE_MATCHERS.find { |pattern, _price| model.to_s.match?(pattern) }&.last || DEFAULT_OPENAI_HIGH
    end
  end

  class Null < Base
    private

    def price_for(_model) = nil
  end
end
