require "rails_helper"

RSpec.describe AgentPricing do
  it "estimates Claude Sonnet cost from token usage" do
    estimate = AgentPricing::Base.for("claude").estimate(
      input_tokens: 1_000_000,
      output_tokens: 100_000,
      cache_creation_input_tokens: 10_000,
      cache_read_input_tokens: 100_000,
      model: "claude-sonnet-4-6"
    )

    expect(estimate).to eq(BigDecimal("4.5675"))
  end

  it "estimates Codex cost from token usage" do
    estimate = AgentPricing::Base.for("codex").estimate(
      input_tokens: 1_000_000,
      output_tokens: 100_000,
      cache_read_input_tokens: 100_000,
      model: "gpt-5.2-codex"
    )

    expect(estimate).to eq(BigDecimal("3.1675"))
  end

  it "returns nil for unknown providers" do
    estimate = AgentPricing::Base.for("unknown").estimate(
      input_tokens: 1_000_000,
      output_tokens: 100_000,
      model: "mystery"
    )

    expect(estimate).to be_nil
  end

  it "does not estimate Antigravity until Gemini pricing is modeled" do
    estimate = AgentPricing::Base.for("agy").estimate(
      input_tokens: 1_000_000,
      output_tokens: 100_000,
      model: "gemini-3-pro"
    )

    expect(estimate).to be_nil
  end
end
