require "rails_helper"

RSpec.describe PushDevice do
  let(:user) { Factories.user }

  it "normalizes and validates tokens" do
    device = described_class.register!(user: user, token: " #{'AB' * 32} ")
    expect(device.token).to eq("ab" * 32)
    expect(described_class.new(user: user, token: "zz", last_registered_at: Time.current)).not_to be_valid
  end

  it "re-enables a disabled token on registration" do
    device = described_class.register!(user: user, token: "ab" * 32)
    device.disable!(reason: "Unregistered")
    expect(device).not_to be_active

    described_class.register!(user: user, token: "ab" * 32)
    expect(device.reload).to be_active
    expect(device.disabled_reason).to be_nil
  end

  it "is destroyed with its session" do
    session = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "spec")
    described_class.register!(user: user, token: "ab" * 32, session: session)

    expect { session.destroy! }.to change(described_class, :count).by(-1)
  end
end
