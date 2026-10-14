require "rails_helper"

RSpec.describe ProviderModelUnsupported do
  describe ".detect?" do
    # The exact message a provider returned after serving the same model for
    # thousands of runs, on a paid account with most of its quota unused.
    it "detects a model refused for the account" do
      expect(described_class).to be_detect(
        %({"type":"error","status":400,"error":{"type":"invalid_request_error","message":) +
        %("The 'gpt-5.5' model is not supported when using Codex with a ChatGPT account."}})
      )
    end

    it "detects the no-access phrasing" do
      expect(described_class).to be_detect(
        "The model `gpt-5.5` does not exist or you do not have access to it."
      )
    end

    it "detects a plan-scoped refusal" do
      expect(described_class).to be_detect("model gpt-5.5 not available for your plan")
    end

    it "detects a machine-readable unsupported_model code" do
      expect(described_class).to be_detect(%({"code":"unsupported_model"}))
    end

    # These are transient or unrelated and are already handled elsewhere.
    # Claiming them here would route a recoverable failure to a permanent
    # fault and stop retrying something that would have worked.
    it "ignores a transient provider error" do
      expect(described_class).not_to be_detect("503 service unavailable, upstream overloaded")
    end

    it "ignores an expired credential" do
      expect(described_class).not_to be_detect("auth error code: token_expired")
    end

    it "ignores a rate limit" do
      expect(described_class).not_to be_detect("429 too many requests, rate limited")
    end

    it "ignores an unsupported file type mentioned by an agent" do
      expect(described_class).not_to be_detect("This image format is not supported by the viewer")
    end

    it "is safe on nil" do
      expect(described_class).not_to be_detect(nil)
    end
  end

  describe ".extract_model" do
    it "pulls a quoted model name out of the refusal" do
      expect(described_class.extract_model("The 'gpt-5.5' model is not supported when using Codex"))
        .to eq("gpt-5.5")
    end

    it "pulls a backtick-quoted model name after the word model" do
      expect(described_class.extract_model("The model `gpt-5.2-codex` does not exist or you do not have access to it"))
        .to eq("gpt-5.2-codex")
    end

    it "returns nil when no model is named" do
      expect(described_class.extract_model("unsupported_model")).to be_nil
    end
  end
end
