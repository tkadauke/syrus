require "rails_helper"

RSpec.describe User do
  let(:attrs) { { email_address: "user@example.com", password: "supersecret" } }

  describe "first-signup admin rule" do
    it "promotes the very first user to admin" do
      user = User.create!(attrs)
      expect(user.admin?).to be true
    end

    it "does not promote subsequent users" do
      User.create!(attrs)
      second = User.create!(attrs.merge(email_address: "two@example.com"))
      expect(second.admin?).to be false
    end

    it "does not re-promote on re-save" do
      User.create!(attrs)
      second = User.create!(attrs.merge(email_address: "two@example.com"))
      second.update!(email_address: "two-renamed@example.com")
      expect(second.admin?).to be false
    end
  end

  describe "encrypted credentials" do
    it "round-trips claude_oauth_token, codex credentials, github_token, and telegram_chat_id" do
      user = User.create!(attrs.merge(claude_oauth_token: "oat-abc",
                                      codex_api_key: "sk-codex",
                                      codex_auth_json: Factories.codex_auth_json(access_token: "codex-access"),
                                      github_token: "ghp_xyz",
                                      telegram_chat_id: "123456"))
      reloaded = User.find(user.id)
      expect(reloaded.claude_oauth_token).to eq("oat-abc")
      expect(reloaded.codex_api_key).to eq("sk-codex")
      expect(reloaded.codex_auth_json).to include("codex-access")
      expect(reloaded.github_token).to eq("ghp_xyz")
      expect(reloaded.telegram_chat_id).to eq("123456")
    end

    it "stores ciphertext, not plaintext, in the column" do
      user = User.create!(attrs.merge(claude_oauth_token: "oat-secret", telegram_chat_id: "123456"))
      row = User.connection.select_one("SELECT claude_oauth_token, telegram_chat_id FROM users WHERE id = #{user.id}")
      expect(row["claude_oauth_token"]).not_to include("oat-secret")
      expect(row["telegram_chat_id"]).not_to include("123456")
    end
  end

  describe "agent_provider" do
    it "defaults to claude" do
      expect(User.create!(attrs).agent_provider).to eq("claude")
    end

    it "accepts codex" do
      user = User.create!(attrs.merge(agent_provider: "codex"))
      expect(user.agent_provider).to eq("codex")
    end

    it "rejects unknown providers" do
      user = User.new(attrs.merge(agent_provider: "oracle"))
      expect(user).not_to be_valid
      expect(user.errors[:agent_provider]).to be_present
    end
  end

  describe "auto_approve_mode" do
    it "defaults to never" do
      expect(User.create!(attrs).auto_approve_mode).to eq("never")
    end

    it "accepts grader-gated modes" do
      user = User.create!(attrs.merge(auto_approve_mode: "if_graders_pass_and_tagged_safe"))
      expect(user.auto_approve_mode).to eq("if_graders_pass_and_tagged_safe")
    end

    it "rejects unknown modes" do
      user = User.new(attrs.merge(auto_approve_mode: "always"))
      expect(user).not_to be_valid
      expect(user.errors[:auto_approve_mode]).to be_present
    end
  end

  describe "codex_auth_mode" do
    it "defaults to api_key" do
      expect(User.create!(attrs).codex_auth_mode).to eq("api_key")
    end

    it "accepts chatgpt_login" do
      user = User.create!(attrs.merge(codex_auth_mode: "chatgpt_login"))
      expect(user.codex_auth_mode).to eq("chatgpt_login")
    end

    it "rejects unknown modes" do
      user = User.new(attrs.merge(codex_auth_mode: "browser_cookie"))
      expect(user).not_to be_valid
      expect(user.errors[:codex_auth_mode]).to be_present
    end
  end

  describe "#dashboard_preferences" do
    it "returns dashboard defaults when the column is nil" do
      user = User.create!(attrs)

      expect(user.dashboard_preferences).to eq(User::DASHBOARD_PREFERENCES_DEFAULTS)
    end

    it "normalizes assigned preference keys and values" do
      user = User.create!(attrs)
      user.dashboard_preferences = { last_subject: :jobs, last_view: :kanban }

      expect(user.dashboard_preferences).to include("last_subject" => "job", "last_view" => "kanban")
      expect(user.dashboard_preferences["jobs"]).to eq(User::DASHBOARD_PREFERENCES_DEFAULTS.fetch("jobs"))
    end

    it "returns default sort for a user with no stored preferences" do
      user = User.create!(attrs)

      expect(user.dashboard_sort(:jobs)).to eq(column: "created_at", direction: "desc")
    end

    it "always includes required visible columns when stored preferences omit them" do
      user = User.create!(
        attrs.merge(
          dashboard_preferences: {
            workflows: {
              visible_columns: %w[state finished_at]
            }
          }
        )
      )

      expect(user.dashboard_visible_columns(:workflows)).to eq(%w[title job state finished_at])
    end

    it "rejects unknown dashboard sort columns" do
      user = User.create!(attrs)

      expect {
        user.update_dashboard_sort!(subject: :jobs, column: "priority", direction: "asc")
      }.to raise_error(ArgumentError, "Unknown dashboard sort column: priority")
    end

    it "persists required columns with selected dashboard columns" do
      user = User.create!(attrs)

      user.update_dashboard_columns!(subject: :jobs, columns: %w[state repository])

      expect(user.reload.dashboard_visible_columns(:jobs)).to eq(%w[title state repository])
    end
  end

  describe "#update_dashboard_columns!" do
    it "re-adds required Dashboard columns when optional choices omit them" do
      user = User.create!(attrs)

      user.update_dashboard_columns!(subject: "jobs", columns: %w[state])

      expect(user.dashboard_visible_columns("jobs")).to include("checkbox", "issue", "state")
    end
  end

  describe "#configured_agent_providers" do
    it "includes Claude when a Claude token is set" do
      user = User.create!(attrs.merge(claude_oauth_token: "oat-test"))

      expect(user.configured_agent_providers).to eq([ "claude" ])
    end

    it "includes Codex when API key auth is selected and an API key is set" do
      user = User.create!(attrs.merge(codex_auth_mode: "api_key", codex_api_key: "sk-test"))

      expect(user.configured_agent_providers).to eq([ "codex" ])
    end

    it "includes Codex when ChatGPT login auth is selected and auth.json is set" do
      user = User.create!(
        attrs.merge(
          codex_auth_mode: "chatgpt_login",
          codex_auth_json: Factories.codex_auth_json(access_token: "access-test")
        )
      )

      expect(user.configured_agent_providers).to eq([ "codex" ])
    end

    it "requires credentials for the active Codex auth mode" do
      user = User.create!(
        attrs.merge(
          codex_auth_mode: "chatgpt_login",
          codex_api_key: "sk-unused-for-chatgpt-login"
        )
      )

      expect(user.configured_agent_providers).to be_empty
    end

    it "returns every configured provider in registry order" do
      user = User.create!(
        attrs.merge(
          claude_oauth_token: "oat-test",
          codex_auth_mode: "api_key",
          codex_api_key: "sk-test"
        )
      )

      expect(user.configured_agent_providers).to eq(%w[ claude codex ])
    end

    it "returns configured providers other than the user's default provider" do
      user = User.create!(
        attrs.merge(
          agent_provider: "claude",
          claude_oauth_token: "oat-test",
          codex_auth_mode: "api_key",
          codex_api_key: "sk-test"
        )
      )

      expect(user.alternate_configured_agent_providers).to eq([ "codex" ])
    end
  end

  describe "#chat_available?" do
    it "is available for a Claude-default user with Claude credentials" do
      user = User.create!(attrs.merge(agent_provider: "claude", claude_oauth_token: "oat-test"))

      expect(user).to be_chat_available
    end

    it "is available for a Codex-default user with Claude credentials" do
      user = User.create!(
        attrs.merge(
          agent_provider: "codex",
          claude_oauth_token: "oat-test",
          codex_auth_mode: "api_key",
          codex_api_key: "sk-test"
        )
      )

      expect(user).to be_chat_available
    end

    it "is unavailable without Claude credentials" do
      user = User.create!(
        attrs.merge(
          agent_provider: "codex",
          codex_auth_mode: "api_key",
          codex_api_key: "sk-test"
        )
      )

      expect(user).not_to be_chat_available
    end
  end

  describe "email normalization" do
    it "downcases and strips whitespace" do
      user = User.create!(attrs.merge(email_address: "  Mixed@Example.com  "))
      expect(user.email_address).to eq("mixed@example.com")
    end
  end

  describe "agent_max_turns" do
    it "defaults to 200 for new users" do
      user = User.create!(attrs)
      expect(user.agent_max_turns).to eq(200)
    end

    it "accepts a value within range" do
      user = User.create!(attrs.merge(agent_max_turns: 500))
      expect(user.reload.agent_max_turns).to eq(500)
    end

    it "accepts 0 as the special-case 'no cap' value" do
      user = User.create!(attrs.merge(agent_max_turns: 0))
      expect(user.reload.agent_max_turns).to eq(0)
    end

    it "rejects negative values" do
      user = User.new(attrs.merge(agent_max_turns: -1))
      expect(user).not_to be_valid
      expect(user.errors[:agent_max_turns]).to be_present
    end

    it "rejects values above the range" do
      user = User.new(attrs.merge(agent_max_turns: User::AGENT_MAX_TURNS_RANGE.last + 1))
      expect(user).not_to be_valid
      expect(user.errors[:agent_max_turns]).to be_present
    end

    it "rejects non-integer values" do
      user = User.new(attrs.merge(agent_max_turns: 3.5))
      expect(user).not_to be_valid
      expect(user.errors[:agent_max_turns]).to be_present
    end
  end

  describe "GH API blocked flag" do
    let(:user) { Factories.user }

    it "is not blocked by default" do
      expect(user).not_to be_gh_api_blocked
    end

    it "mark_gh_api_blocked! sets timestamp + reason" do
      user.mark_gh_api_blocked!("Resource not accessible")
      expect(user).to be_gh_api_blocked
      expect(user.gh_api_blocked_reason).to eq("Resource not accessible")
    end

    it "is idempotent for the same reason — doesn't rewrite the row" do
      user.mark_gh_api_blocked!("same reason")
      first_at = user.gh_api_blocked_at
      sleep 0.01
      user.mark_gh_api_blocked!("same reason")
      expect(user.reload.gh_api_blocked_at).to be_within(0.001).of(first_at)
    end

    it "updates the timestamp when the reason changes" do
      user.mark_gh_api_blocked!("first reason")
      first_at = user.gh_api_blocked_at
      sleep 0.01
      user.mark_gh_api_blocked!("second reason")
      expect(user.reload.gh_api_blocked_reason).to eq("second reason")
      expect(user.gh_api_blocked_at).to be > first_at
    end

    it "clear_gh_api_blocked! resets timestamp + reason when blocked" do
      user.mark_gh_api_blocked!("anything")
      user.clear_gh_api_blocked!
      expect(user).not_to be_gh_api_blocked
      expect(user.reload.gh_api_blocked_reason).to be_nil
    end

    it "truncates very long reasons to fit the column" do
      user.mark_gh_api_blocked!("x" * 1000)
      expect(user.reload.gh_api_blocked_reason.length).to be <= 500
    end
  end
end
