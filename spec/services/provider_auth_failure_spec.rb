require "rails_helper"

RSpec.describe ProviderAuthFailure do
  describe ".detect?" do
    it "recognizes locally missing provider credentials as an auth failure" do
      expect(described_class.detect?("Codex API key is not configured")).to be(true)
      expect(described_class.detect?("provider credentials are missing")).to be(true)
    end
  end
end
