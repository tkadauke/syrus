require "rails_helper"

RSpec.describe Installation do
  it "encrypts cached installation tokens at rest" do
    installation = Installation.create!(
      user: Factories.user,
      github_installation_id: 123,
      account_login: "acme",
      account_id: 456,
      account_type: "Organization",
      installed_at: Time.current,
      cached_token: "installation-token"
    )

    raw = Installation.connection.select_value(
      "SELECT cached_token FROM installations WHERE id = #{installation.id}"
    )
    expect(raw).not_to include("installation-token")
    expect(installation.reload.cached_token).to eq("installation-token")
  end
end
