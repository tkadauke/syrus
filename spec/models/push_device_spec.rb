require "rails_helper"

RSpec.describe PushDevice do
  it "is destroyed with its session so sign-out stops pushes" do
    user = Factories.user
    session = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "spec")
    PushDevice.create!(user: user, session: session, token: "ab" * 32, last_registered_at: Time.current)

    expect { session.destroy }.to change(PushDevice, :count).by(-1)
  end

  it "scopes active devices" do
    user = Factories.user
    PushDevice.create!(user: user, token: "ab" * 32, last_registered_at: Time.current)
    dead = PushDevice.create!(user: user, token: "cd" * 32, last_registered_at: Time.current)
    dead.disable!("Unregistered")

    expect(PushDevice.active.count).to eq(1)
  end
end
