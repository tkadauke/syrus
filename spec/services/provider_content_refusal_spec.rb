require "rails_helper"

RSpec.describe ProviderContentRefusal do
  it "recognizes safety-filter refusals" do
    expect(described_class.detect?("This content was flagged for possible cybersecurity risk. If this seems wrong, try rephrasing your request.")).to be(true)
    expect(described_class.detect?("API Error: Claude Code is unable to respond to this request, which appears to violate our Usage Policy")).to be(true)
  end

  it "does not match ordinary provider failures" do
    expect(described_class.detect?("stream disconnected before completion")).to be(false)
    expect(described_class.detect?("The 'gpt-5.5' model is not supported when using Codex")).to be(false)
  end
end
