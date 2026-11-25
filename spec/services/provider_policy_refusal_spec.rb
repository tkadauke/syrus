require "rails_helper"

RSpec.describe ProviderPolicyRefusal do
  it "recognizes an explicit provider safety refusal" do
    expect(described_class.detect?("I can't assist with this request because it is disallowed by our safety policy.")).to be(true)
  end

  it "does not classify an ordinary review discussion that mentions policy" do
    expect(described_class.detect?("The authorization policy needs a regression spec before approval.")).to be(false)
  end
end
