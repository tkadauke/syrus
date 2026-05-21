require "rails_helper"

RSpec.describe Admin::Users::Filter do
  let!(:admin_user) { Factories.user(email_address: "admin@example.com") }
  let!(:plain_user) { Factories.user(email_address: "ophelia@example.com") }
  let!(:gh_token_user) { Factories.user(email_address: "alice@example.com", github_token: "ghp_x") }
  let!(:claude_user) { Factories.user(email_address: "bob@example.com", claude_oauth_token: "co_x") }
  let!(:codex_user) { Factories.user(email_address: "cora@example.com", codex_api_key: "sk_x") }
  let!(:codex_login_user) do
    Factories.user(email_address: "dana@example.com",
                   codex_auth_mode: "chatgpt_login",
                   codex_auth_json: Factories.codex_auth_json(access_token: "access_x"))
  end
  let!(:rate_low_user) do
    Factories.user(email_address: "lila@example.com",
                   gh_rate_limit_remaining: 50,
                   gh_rate_limit_limit: 5000)
  end
  let!(:rate_ok_user) do
    Factories.user(email_address: "rita@example.com",
                   gh_rate_limit_remaining: 4000,
                   gh_rate_limit_limit: 5000)
  end
  let!(:rate_zero_user) do
    Factories.user(email_address: "zeke@example.com",
                   gh_rate_limit_remaining: 0,
                   gh_rate_limit_limit: 5000)
  end

  def filter_from_tree(field, op, value)
    described_class.from_tree({ "and" => [ { "field" => field, "op" => op, "value" => value } ] }, user: admin_user)
  end

  it "returns all users by default" do
    expect(described_class.from_params({}, user: admin_user).apply(User.all).size).to eq(User.count)
  end

  it "filters by email contains" do
    filter = filter_from_tree("email", "contains", "alice")

    expect(filter.apply(User.all)).to contain_exactly(gh_token_user)
  end

  it "filters by admin=true" do
    filter = filter_from_tree("admin", "is", "true")

    expect(filter.apply(User.all)).to contain_exactly(admin_user)
  end

  it "filters by has_github_token=false" do
    filter = filter_from_tree("has_github_token", "is", "false")

    expect(filter.apply(User.all)).not_to include(gh_token_user)
    expect(filter.apply(User.all)).to include(admin_user, plain_user)
  end

  it "filters by Claude OAuth token presence" do
    filter = filter_from_tree("has_claude_token", "is", "true")

    expect(filter.apply(User.all)).to contain_exactly(claude_user)
  end

  it "filters by any Codex credential" do
    filter = filter_from_tree("has_codex_token", "is", "true")

    expect(filter.apply(User.all)).to contain_exactly(codex_user, codex_login_user)
  end

  it "filters by low GitHub rate limit" do
    filter = filter_from_tree("gh_rate", "is", "low")

    expect(filter.apply(User.all)).to include(rate_low_user, rate_zero_user)
    expect(filter.apply(User.all)).not_to include(rate_ok_user)
  end

  it "translates legacy flat URL params into chips" do
    filter = described_class.from_params({ admin: "true", gh_rate: "low" }, user: admin_user)
    admin_user.update!(gh_rate_limit_remaining: 10, gh_rate_limit_limit: 5000)

    expect(filter.apply(User.all)).to contain_exactly(admin_user)
  end

  it "round-trips through the q= query param format" do
    tree = { "and" => [ { "field" => "email", "op" => "contains", "value" => "alice" } ] }
    filter = described_class.from_tree(tree, user: admin_user)

    expect(Filters::QueryParam.decode(filter.to_query_param)).to eq(tree)
  end
end
