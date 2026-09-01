require "rails_helper"

RSpec.describe Filters::Chips::AdminUsers::HasClaudeToken do
  let!(:without_token) { Factories.user(email_address: "plain@example.com", claude_oauth_token: nil) }
  let!(:with_token) { Factories.user(email_address: "claude@example.com", claude_oauth_token: "co_x") }

  def run(value)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "has_claude_token", "op" => "is", "value" => value),
      scope: User.all,
      user: with_token,
      subject: :admin_user
    )
  end

  it "is registered on the admin_user subject by the Claude plugin" do
    expect(Filters::Registry.find("has_claude_token", subject: :admin_user)).to eq(described_class)
  end

  it "matches users with Claude OAuth tokens" do
    expect(run("true")).to contain_exactly(with_token)
  end

  it "matches users without Claude OAuth tokens" do
    expect(run("false")).to include(without_token)
    expect(run("false")).not_to include(with_token)
  end
end
