require "rails_helper"

RSpec.describe User, "handle" do
  it "generates a normalized handle from the GitHub handle" do
    user = Factories.user(email_address: "fallback@example.com", github_handle: "@Ada.Lovelace")

    expect(user.handle).to eq("ada-lovelace")
  end

  it "requires persisted users to keep a handle" do
    user = Factories.user
    HandleRegistry.release!(owner: user)

    expect(user.update(name: "Missing handle")).to be(false)
    expect(user.errors[:handle]).to include("is required")
  end
end
