require "rails_helper"

RSpec.describe BrowserErrorAutoReport do
  let(:user) { Factories.user }

  def browser_error(fingerprint: "abc123", revision: "sha-one")
    BrowserErrorEvent.create!(
      user: user,
      occurred_at: Time.current,
      app_revision: revision,
      fingerprint: fingerprint,
      message: "undefined is not an object",
      path: "/jobs/3188"
    )
  end

  it "claims one report per fingerprint and revision" do
    first = browser_error
    second = browser_error

    expect(described_class.claim_for!(first)).to be_present
    expect(described_class.claim_for!(second)).to be_nil
  end

  it "allows the same fingerprint on a new revision" do
    first = browser_error(revision: "sha-one")
    second = browser_error(revision: "sha-two")

    expect(described_class.claim_for!(first)).to be_present
    expect(described_class.claim_for!(second)).to be_present
  end
end
