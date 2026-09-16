require "rails_helper"

RSpec.describe Filters::Chips::AdminUsers::HasMuseToken do
  before do
    PluginRecord.find_or_create_by!(name: "muse_agent").update!(enabled: true, default_enabled: false, disableable: true)
  end

  let!(:without_token) { Factories.user(email_address: "plain@example.com", muse_api_key: nil) }
  let!(:with_token) { Factories.user(email_address: "muse@example.com", muse_api_key: "muse_x") }

  def run(value)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "has_muse_token", "op" => "is", "value" => value),
      scope: User.all,
      user: with_token,
      subject: :admin_user
    )
  end

  it "is registered on the admin_user subject by the Muse plugin" do
    expect(Filters::Registry.find("has_muse_token", subject: :admin_user)).to eq(described_class)
  end

  it "matches users with Muse API keys" do
    expect(run("true")).to include(with_token)
    expect(run("true")).not_to include(without_token)
  end

  it "matches users without Muse credentials" do
    expect(run("false")).to include(without_token)
    expect(run("false")).not_to include(with_token)
  end
end
