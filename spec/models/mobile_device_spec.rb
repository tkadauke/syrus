require "rails_helper"

RSpec.describe MobileDevice do
  let(:user) { Factories.user }
  let(:attrs) { { token: "AB" * 32, bundle_id: "dev.syrus.app", apns_environment: "sandbox" } }

  it "registers idempotently, normalising the token to lowercase" do
    first = described_class.register!(user: user, session: nil, attributes: attrs)
    second = described_class.register!(user: user, session: nil, attributes: attrs.merge(device_name: "Phone"))

    expect(second.id).to eq(first.id)
    expect(second.token).to eq("ab" * 32)
    expect(second.device_name).to eq("Phone")
  end

  it "moves a token to the new user and re-enables it" do
    other = Factories.user
    device = described_class.register!(user: user, session: nil, attributes: attrs)
    device.disable!("Unregistered")

    moved = described_class.register!(user: other, session: nil, attributes: attrs)

    expect(moved.id).to eq(device.id)
    expect(moved.user).to eq(other)
    expect(moved.disabled_at).to be_nil
  end

  it "rejects non-hex tokens" do
    expect { described_class.register!(user: user, session: nil, attributes: attrs.merge(token: "not hex!")) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end

  it "is destroyed with its session" do
    session = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "spec")
    described_class.register!(user: user, session: session, attributes: attrs)

    expect { session.destroy }.to change(described_class, :count).by(-1)
  end
end
