require "rails_helper"

RSpec.describe Filters::Chips::AdminUsers::HasCodexToken do
  let!(:without_token) { Factories.user(email_address: "plain@example.com", codex_api_key: nil, codex_auth_json: nil) }
  let!(:with_api_key) { Factories.user(email_address: "codex-key@example.com", codex_api_key: "sk_x", codex_auth_json: nil) }
  let!(:with_auth_json) { Factories.user(email_address: "codex-auth@example.com", codex_api_key: nil, codex_auth_json: Factories.codex_auth_json) }

  def run(value)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "has_codex_token", "op" => "is", "value" => value),
      scope: User.all,
      user: with_api_key,
      subject: :admin_user
    )
  end

  it "is registered on the admin_user subject by the Codex plugin" do
    expect(Filters::Registry.find("has_codex_token", subject: :admin_user)).to eq(described_class)
  end

  it "matches users with Codex API keys or auth.json credentials" do
    expect(run("true")).to include(with_api_key, with_auth_json)
    expect(run("true")).not_to include(without_token)
  end

  it "matches users without Codex credentials" do
    expect(run("false")).to include(without_token)
    expect(run("false")).not_to include(with_api_key)
    expect(run("false")).not_to include(with_auth_json)
  end
end
