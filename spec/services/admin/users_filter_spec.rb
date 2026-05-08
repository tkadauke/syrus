require "rails_helper"

RSpec.describe Admin::UsersFilter do
  # First user auto-promotes to admin via the User model's
  # first-user-is-admin hook; subsequent users are non-admin.
  let!(:admin_user)     { Factories.user(email_address: "admin@example.com") }
  let!(:plain_user)     { Factories.user(email_address: "ophelia@example.com") }
  let!(:gh_token_user)  { Factories.user(email_address: "alice@example.com", github_token: "ghp_x") }
  let!(:claude_user)    { Factories.user(email_address: "bob@example.com", claude_oauth_token: "co_x") }
  let!(:codex_user)     { Factories.user(email_address: "cora@example.com", codex_api_key: "sk_x") }
  let!(:codex_login_user) do
    Factories.user(email_address: "dana@example.com",
                   codex_auth_mode: "chatgpt_login",
                   codex_auth_json: Factories.codex_auth_json(access_token: "access_x"))
  end
  let!(:rate_low_user)  { Factories.user(email_address: "lila@example.com",
                                          gh_rate_limit_remaining: 50, gh_rate_limit_limit: 5000) }
  let!(:rate_ok_user)   { Factories.user(email_address: "rita@example.com",
                                          gh_rate_limit_remaining: 4000, gh_rate_limit_limit: 5000) }
  let!(:rate_zero_user) { Factories.user(email_address: "zeke@example.com",
                                          gh_rate_limit_remaining: 0, gh_rate_limit_limit: 5000) }

  it "returns all users by default" do
    expect(described_class.new({}).scope.size).to eq(User.count)
  end

  describe "email filter" do
    it "matches case-sensitively on substring" do
      expect(described_class.new(email: "alice").scope).to contain_exactly(gh_token_user)
    end

    it "ignores blank values" do
      expect(described_class.new(email: "  ").scope.size).to eq(User.count)
    end
  end

  describe "admin filter" do
    it "filters to admins when admin=true" do
      expect(described_class.new(admin: "true").scope).to contain_exactly(admin_user)
    end

    it "filters out admins when admin=false" do
      expect(described_class.new(admin: "false").scope).not_to include(admin_user)
    end

    it "ignores garbage values (no narrowing)" do
      expect(described_class.new(admin: "maybe").scope.size).to eq(User.count)
    end
  end

  describe "has_github_token filter" do
    it "true → only users with a token set" do
      expect(described_class.new(has_github_token: "true").scope).to contain_exactly(gh_token_user)
    end

    it "false → only users without a token" do
      expect(described_class.new(has_github_token: "false").scope).not_to include(gh_token_user)
    end
  end

  describe "has_claude_token filter" do
    it "true → only users with a Claude OAuth token" do
      expect(described_class.new(has_claude_token: "true").scope).to contain_exactly(claude_user)
    end
  end

  describe "has_codex_token filter" do
    it "true → only users with any Codex credential" do
      expect(described_class.new(has_codex_token: "true").scope)
        .to contain_exactly(codex_user, codex_login_user)
    end

    it "false → only users without any Codex credential" do
      result = described_class.new(has_codex_token: "false").scope
      expect(result).not_to include(codex_user, codex_login_user)
    end
  end

  describe "gh_rate filter" do
    it "low → users below the 10% threshold (and not zero, since zero is its own bucket too)" do
      result = described_class.new(gh_rate: "low").scope
      expect(result).to include(rate_low_user, rate_zero_user)
      expect(result).not_to include(rate_ok_user)
    end

    it "exhausted → only users with zero remaining" do
      expect(described_class.new(gh_rate: "exhausted").scope).to contain_exactly(rate_zero_user)
    end

    it "ignores unknown values" do
      expect(described_class.new(gh_rate: "extreme").scope.size).to eq(User.count)
    end
  end

  describe "filters compose (AND, not OR)" do
    let!(:admin_with_low_rate) { admin_user.update!(gh_rate_limit_remaining: 10, gh_rate_limit_limit: 5000); admin_user }

    it "applies all provided filters together" do
      result = described_class.new(admin: "true", gh_rate: "low").scope
      expect(result).to contain_exactly(admin_with_low_rate)
    end
  end

  describe "#active_filters" do
    it "is empty when no filters are provided" do
      expect(described_class.new({}).active_filters).to eq({})
    end

    it "lists each provided filter for the UI strip" do
      f = described_class.new(email: "foo", admin: "true", has_codex_token: "false", gh_rate: "low")
      expect(f.active_filters).to eq("email" => "foo", "admin" => "yes", "has_codex_token" => "no", "gh_rate" => "low")
    end
  end
end
