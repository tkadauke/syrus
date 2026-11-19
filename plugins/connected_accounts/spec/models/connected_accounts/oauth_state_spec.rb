require "rails_helper"

RSpec.describe ConnectedAccounts::OauthState do
  let(:user) { Factories.user }

  it "is bound to user and session, expires, and is single use" do
    token, = described_class.issue!(user: user, session_binding: "browser-a", provider: "fake", requested_scopes: [ "fake.read" ], read_only: true)
    expect { described_class.consume!(token: token, user: user, session_binding: "browser-b", provider: "fake") }.to raise_error(ActiveRecord::RecordNotFound)
    state = described_class.consume!(token: token, user: user, session_binding: "browser-a", provider: "fake")
    expect(state).to be_read_only
    expect { described_class.consume!(token: token, user: user, session_binding: "browser-a", provider: "fake") }.to raise_error(ActiveRecord::RecordNotFound)

    expired, = described_class.issue!(user: user, session_binding: "browser-a", provider: "fake", requested_scopes: [], read_only: false)
    travel 11.minutes
    expect { described_class.consume!(token: expired, user: user, session_binding: "browser-a", provider: "fake") }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
