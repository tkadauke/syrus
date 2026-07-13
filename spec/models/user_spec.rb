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

  describe "profile fields" do
    it "keeps legacy display names stable when profile fields are blank" do
      user = User.create!(attrs)
      named_user = User.create!(attrs.merge(email_address: "named@example.com", name: "Operator"))

      expect(user.display_name).to eq("user@example.com")
      expect(named_user.display_name).to eq("Operator")
    end

    it "stores normalized safe profile fields and can use first and last name as a display fallback" do
      user = User.create!(
        attrs.merge(
          name: " ",
          first_name: " Ada ",
          last_name: " Lovelace ",
          profile_bio: "  Mathematician and operator.  ",
          profile_location: " London ",
          profile_company: " Analytical Engines Ltd ",
          profile_website: " https://example.com/ada "
        )
      )

      expect(user.reload).to have_attributes(
        first_name: "Ada",
        last_name: "Lovelace",
        profile_bio: "Mathematician and operator.",
        profile_location: "London",
        profile_company: "Analytical Engines Ltd",
        profile_website: "https://example.com/ada"
      )
      expect(user.full_name).to eq("Ada Lovelace")
      expect(user.display_name).to eq("Ada Lovelace")
    end

    it "caps profile fields at modest lengths" do
      user = User.new(attrs.merge(profile_company: "x" * 101))
      bio_user = User.new(attrs.merge(profile_bio: "x" * 1001))

      expect(user).not_to be_valid
      expect(user.errors[:profile_company]).to be_present
      expect(bio_user).not_to be_valid
      expect(bio_user.errors[:profile_bio]).to be_present
    end
  end

  describe "encrypted credentials" do
    it "stores variable-length encrypted secret payloads in text columns" do
      column_types = User.columns.index_by(&:name).transform_values(&:type)

      expect(column_types.values_at("claude_oauth_token", "codex_api_key", "github_token", "api_token"))
        .to all(eq(:text))
    end

    it "round-trips claude_oauth_token, codex credentials, and github_token" do
      user = User.create!(attrs.merge(claude_oauth_token: "oat-abc",
                                      codex_api_key: "sk-codex",
                                      codex_auth_json: Factories.codex_auth_json(access_token: "codex-access"),
                                      github_token: "ghp_xyz"))
      reloaded = User.find(user.id)
      expect(reloaded.claude_oauth_token).to eq("oat-abc")
      expect(reloaded.codex_api_key).to eq("sk-codex")
      expect(reloaded.codex_auth_json).to include("codex-access")
      expect(reloaded.github_token).to eq("ghp_xyz")
    end

    it "stores ciphertext, not plaintext, in the column" do
      user = User.create!(attrs.merge(claude_oauth_token: "oat-secret"))
      row = User.connection.select_one("SELECT claude_oauth_token FROM users WHERE id = #{user.id}")
      expect(row["claude_oauth_token"]).not_to include("oat-secret")
    end

    it "round-trips encrypted credential payloads larger than a string column" do
      long_token = "oat-" + ("x" * 1_024)

      user = User.create!(attrs.merge(claude_oauth_token: long_token,
                                      codex_api_key: "sk-" + ("y" * 1_024),
                                      github_token: "ghp_" + ("z" * 1_024)))

      expect(user.reload.claude_oauth_token).to eq(long_token)
      expect(user.codex_api_key).to eq("sk-" + ("y" * 1_024))
      expect(user.github_token).to eq("ghp_" + ("z" * 1_024))
    end

    it "clears only declared clearable credentials" do
      user = User.create!(attrs.merge(github_token: "ghp_xyz", claude_oauth_token: "oat-abc"))

      user.clear_credential!("github_token")

      expect(user.reload.github_token).to be_nil
      expect(user.claude_oauth_token).to eq("oat-abc")
    end

    it "rejects clearing non-credential attributes" do
      user = User.create!(attrs)

      expect {
        user.clear_credential!("email_address")
      }.to raise_error(ArgumentError, "Unknown credential: email_address")
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

  describe "chat_provider" do
    it "defaults to inheriting the agent provider" do
      user = User.create!(attrs.merge(agent_provider: "codex"))

      expect(user.chat_provider).to be_nil
      expect(user.effective_chat_provider).to eq("codex")
    end

    it "accepts supported chat providers" do
      user = User.create!(attrs.merge(agent_provider: "codex", chat_provider: "claude"))

      expect(user.chat_provider).to eq("claude")
      expect(user.effective_chat_provider).to eq("claude")
    end

    it "normalizes blank chat providers to inheritance" do
      user = User.create!(attrs.merge(chat_provider: ""))

      expect(user.chat_provider).to be_nil
      expect(user.effective_chat_provider).to eq("claude")
    end

    it "rejects unknown chat providers" do
      user = User.new(attrs.merge(chat_provider: "oracle"))

      expect(user).not_to be_valid
      expect(user.errors[:chat_provider]).to be_present
    end
  end

  describe "theme" do
    it "defaults to light" do
      expect(User.create!(attrs).theme).to eq("light")
    end

    it "accepts dark" do
      user = User.create!(attrs.merge(theme: "dark"))
      expect(user.theme).to eq("dark")
    end

    it "rejects unknown themes" do
      user = User.new(attrs.merge(theme: "system"))
      expect(user).not_to be_valid
      expect(user.errors[:theme]).to be_present
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

    it "keeps newly selectable timestamp columns out of the default dashboard columns" do
      user = User.create!(attrs)

      expect(user.dashboard_visible_columns(:epics)).to eq(%w[epic state repository updated])
      expect(user.dashboard_visible_columns(:jobs)).to eq(%w[checkbox issue state repository latest workflows_count started])
      expect(user.dashboard_visible_columns(:workflows)).to eq(%w[title job workflow trigger state started finished agent])
    end

    it "returns default Kanban lanes for each dashboard subject" do
      user = User.create!(attrs)

      expect(user.dashboard_visible_kanban_lanes(:epics)).to eq(%w[backlog ready in_progress done])
      expect(user.dashboard_visible_kanban_lanes(:jobs)).to eq(%w[queued running landing])
      expect(user.dashboard_visible_kanban_lanes(:workflows)).to eq(%w[queued running done])
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
      expect(user.dashboard_sort(:workflows)).to eq("column" => "started_at", "direction" => "desc")
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

    it "persists selected Kanban lanes" do
      user = User.create!(attrs)

      user.update_dashboard_kanban_lanes!(subject: :jobs, lanes: %w[blocked running failed])

      expect(user.reload.dashboard_visible_kanban_lanes(:jobs)).to eq(%w[blocked running failed])
      expect(user.dashboard_preferences.fetch("jobs").fetch("kanban_lanes")).to eq(%w[blocked running failed])
    end

    it "persists the dashboard view per subject" do
      user = User.create!(attrs)

      user.update_dashboard_view!(subject: :jobs, view: "kanban")

      preferences = user.reload.dashboard_preferences
      expect(preferences.dig("jobs", "last_view")).to eq("kanban")
      expect(preferences.dig("epics", "last_view")).to eq("list")
    end

    it "persists dashboard view and sort per folder" do
      user = User.create!(attrs)

      user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: nil, view: "kanban")
      user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 42, sort_column: "landing_queue_position", sort_direction: "asc")

      preferences = user.reload.dashboard_preferences.fetch("jobs").fetch("folder_prefs")
      expect(preferences.fetch("null")).to eq("view" => "kanban")
      expect(preferences.fetch("42")).to eq(
        "sort_column" => "landing_queue_position",
        "sort_direction" => "asc"
      )
    end

    it "preserves existing folder sort when saving folder view" do
      user = User.create!(attrs)
      user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 42, sort_column: "created_at", sort_direction: "desc")

      user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 42, view: "kanban")

      expect(user.reload.dashboard_preferences.dig("jobs", "folder_prefs", "42")).to eq(
        "sort_column" => "created_at",
        "sort_direction" => "desc",
        "view" => "kanban"
      )
    end

    it "preserves existing folder view when saving folder sort" do
      user = User.create!(attrs)
      user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 42, view: "kanban")

      user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 42, sort_column: "started_at", sort_direction: "asc")

      expect(user.reload.dashboard_preferences.dig("jobs", "folder_prefs", "42")).to eq(
        "view" => "kanban",
        "sort_column" => "started_at",
        "sort_direction" => "asc"
      )
    end

    it "rejects unknown folder dashboard preferences" do
      user = User.create!(attrs)

      expect {
        user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 42, view: "board")
      }.to raise_error(ArgumentError, "Unknown dashboard view: board")
      expect {
        user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 42, sort_column: "priority", sort_direction: "asc")
      }.to raise_error(ArgumentError, "Unknown dashboard sort column: priority")
      expect {
        user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 42, sort_column: "created_at", sort_direction: "sideways")
      }.to raise_error(ArgumentError, "Unknown dashboard sort direction: sideways")
    end

    it "keeps folder preference slots independent within a subject" do
      user = User.create!(attrs)

      user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 12, view: "kanban")
      user.update_dashboard_folder_preferences!(subject: :jobs, smart_folder_id: 34, view: "list")

      preferences = user.reload.dashboard_preferences.fetch("jobs").fetch("folder_prefs")
      expect(preferences.fetch("12")).to eq("view" => "kanban")
      expect(preferences.fetch("34")).to eq("view" => "list")
    end

    it "rejects unknown dashboard views" do
      user = User.create!(attrs)

      expect {
        user.update_dashboard_view!(subject: :jobs, view: "board")
      }.to raise_error(ArgumentError, "Unknown dashboard view: board")
    end

    it "persists and clears the dashboard smart folder per subject" do
      user = User.create!(attrs)

      user.update_dashboard_smart_folder!(subject: :workflows, smart_folder_id: 12)
      expect(user.reload.dashboard_preferences.dig("workflows", "last_smart_folder_id")).to eq("12")

      user.update_dashboard_smart_folder!(subject: :workflows, smart_folder_id: nil)
      expect(user.reload.dashboard_preferences.dig("workflows", "last_smart_folder_id")).to be_nil
    end

    it "falls back to the per-subject ownership default" do
      user = User.create!(attrs)

      user.update_dashboard_ownership!(subject: :jobs, scope: nil)
      user.update_dashboard_ownership!(subject: :epics, scope: nil)
      user.update_dashboard_ownership!(subject: :workflows, scope: nil)

      preferences = user.reload.dashboard_preferences
      expect(preferences.dig("jobs", "ownership_scope")).to eq("team")
      expect(preferences.dig("epics", "ownership_scope")).to eq("team")
      expect(preferences.dig("workflows", "ownership_scope")).to eq("mine")
    end

    it "rejects unknown Kanban lanes" do
      user = User.create!(attrs)

      expect {
        user.update_dashboard_kanban_lanes!(subject: :workflows, lanes: %w[queued vaporized])
      }.to raise_error(ArgumentError, "Unknown dashboard Kanban lanes: vaporized")
    end
  end

  describe "#notification_preference_for" do
    it "returns the default notification preferences when none are stored" do
      user = User.create!(attrs)

      expect(user.notification_preferences).to eq(User::NOTIFICATION_PREFERENCES_DEFAULTS)
      expect(user.notification_preference_for("job_failed")).to be(true)
      expect(user.notification_preference_for("epic_completed")).to be(false)
      expect(user.desktop_notification_enabled?("desktop_job_implemented")).to be(true)
    end

    it "falls back to defaults for missing stored keys" do
      user = User.create!(attrs.merge(notification_preferences: { "job_failed" => false }))

      expect(user.notification_preference_for("job_failed")).to be(false)
      expect(user.notification_preference_for("job_implemented")).to be(true)
      expect(user.desktop_notification_enabled?(:desktop_job_failed)).to be(true)
    end

    it "returns stored desktop notification preferences" do
      user = User.create!(attrs.merge(notification_preferences: { "desktop_job_implemented" => false }))

      expect(user.desktop_notification_enabled?(:desktop_job_implemented)).to be(false)
      expect(user.desktop_notification_enabled?(:desktop_job_failed)).to be(true)
    end

    it "ignores unknown stored keys and coerces values to booleans" do
      user = User.create!(
        attrs.merge(
          notification_preferences: {
            job_failed: "0",
            pr_merged: "1",
            unknown: true
          }
        )
      )

      expect(user.notification_preferences).to include("job_failed" => false, "pr_merged" => true)
      expect(user.notification_preferences).not_to have_key("unknown")
    end
  end

  describe "#update_dashboard_columns!" do
    it "re-adds required Dashboard columns when optional choices omit them" do
      user = User.create!(attrs)

      user.update_dashboard_columns!(subject: "jobs", columns: %w[state])

      expect(user.dashboard_visible_columns("jobs")).to include("checkbox", "issue", "state")
    end

    it "allows timestamp columns for Epics, Jobs, and Workflows" do
      user = User.create!(attrs)

      user.update_dashboard_columns!(subject: "epics", columns: %w[created_at updated_at done_at archived_at])
      user.update_dashboard_columns!(subject: "jobs", columns: %w[created_at updated_at started_at finished_at approved_at dependencies_overridden_at last_feedback_addressed_at last_seen_comment_at pr_mergeable_checked_at])
      user.update_dashboard_columns!(subject: "workflows", columns: %w[created_at updated_at started_at finished_at cleaned_up_at])

      expect(user.dashboard_visible_columns("epics")).to include("created_at", "updated_at", "done_at", "archived_at")
      expect(user.dashboard_visible_columns("jobs")).to include("created_at", "updated_at", "started_at", "finished_at", "approved_at", "dependencies_overridden_at", "last_feedback_addressed_at", "last_seen_comment_at", "pr_mergeable_checked_at")
      expect(user.dashboard_visible_columns("workflows")).to include("created_at", "updated_at", "started_at", "finished_at", "cleaned_up_at")
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

  describe "#agent_provider_configured?" do
    it "returns true for claude when a Claude token is present" do
      user = User.create!(attrs.merge(claude_oauth_token: "oat-test"))

      expect(user.agent_provider_configured?("claude")).to be true
    end

    it "returns false for claude when no token is set" do
      user = User.create!(attrs)

      expect(user.agent_provider_configured?("claude")).to be false
    end

    it "returns true for codex when the active auth mode is satisfied" do
      user = User.create!(attrs.merge(codex_auth_mode: "api_key", codex_api_key: "sk-test"))

      expect(user.agent_provider_configured?("codex")).to be true
    end

    it "returns false for an unknown provider" do
      user = User.create!(attrs.merge(claude_oauth_token: "oat-test"))

      expect(user.agent_provider_configured?("oracle")).to be false
    end
  end

  describe "#codex_configured?" do
    it "is true when api_key mode is selected and a key is present" do
      user = User.create!(attrs.merge(codex_auth_mode: "api_key", codex_api_key: "sk-test"))

      expect(user.send(:codex_configured?)).to be true
    end

    it "is false when api_key mode is selected but no key is set" do
      user = User.create!(attrs.merge(codex_auth_mode: "api_key"))

      expect(user.send(:codex_configured?)).to be false
    end

    it "is true when chatgpt_login mode is selected and auth.json is present" do
      user = User.create!(
        attrs.merge(
          codex_auth_mode: "chatgpt_login",
          codex_auth_json: Factories.codex_auth_json(access_token: "access-test")
        )
      )

      expect(user.send(:codex_configured?)).to be true
    end

    it "is false when chatgpt_login mode is selected but auth.json is blank" do
      user = User.create!(attrs.merge(codex_auth_mode: "chatgpt_login"))

      expect(user.send(:codex_configured?)).to be false
    end

    it "is false for an unknown auth mode" do
      user = User.create!(attrs.merge(codex_auth_mode: "api_key", codex_api_key: "sk-test"))
      allow(user).to receive(:codex_auth_mode).and_return("unknown_mode")

      expect(user.send(:codex_configured?)).to be false
    end
  end

  describe "#chat_available?" do
    it "is available for a Claude-default user with Claude credentials" do
      user = User.create!(attrs.merge(agent_provider: "claude", claude_oauth_token: "oat-test"))

      expect(user).to be_chat_available
    end

    it "is available for a Codex-default user with Codex credentials" do
      user = User.create!(
        attrs.merge(
          agent_provider: "codex",
          codex_auth_mode: "api_key",
          codex_api_key: "sk-test"
        )
      )

      expect(user).to be_chat_available
    end

    it "can override a Codex-default user to require Claude chat credentials" do
      user = User.create!(
        attrs.merge(
          agent_provider: "codex",
          chat_provider: "claude",
          codex_auth_mode: "api_key",
          codex_api_key: "sk-test"
        )
      )

      expect(user).not_to be_chat_available
    end

    it "is unavailable without the inherited chat provider credentials" do
      user = User.create!(
        attrs.merge(
          agent_provider: "codex",
          codex_auth_mode: "api_key"
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

  describe "first-run setup completion" do
    let(:setup_user) { Factories.user }

    it "is incomplete with no Epics, and a merged Job alone does not finish onboarding" do
      repository = Factories.repository(user: setup_user)
      Factories.job_record(user: setup_user, repository: repository, state: "closed", closure_reason: "pr_merged")

      expect(setup_user.first_epic_created?).to be false
      expect(setup_user.first_run_setup_complete?).to be false
    end

    it "tracks the first Epic from created → started → landed" do
      repository = Factories.repository(user: setup_user)
      epic = Factories.epic(user: setup_user, repository: repository, state: "backlog")
      expect(setup_user.first_epic_created?).to be true
      expect(setup_user.first_epic_started?).to be false
      expect(setup_user.first_run_setup_complete?).to be false

      epic.update!(state: "in_progress")
      expect(setup_user.first_epic_started?).to be true
      expect(setup_user.first_run_setup_complete?).to be false

      epic.update!(state: "done")
      expect(setup_user.first_epic_landed?).to be true
      expect(setup_user.first_run_setup_complete?).to be true
    end

    it "stays complete after the landed Epic is archived" do
      repository = Factories.repository(user: setup_user)
      epic = Factories.epic(user: setup_user, repository: repository, state: "in_progress")
      epic.update!(state: "done", done_at: Time.current)

      epic.archive!
      expect(epic.reload.state).to eq("archived")
      expect(setup_user.first_epic_landed?).to be true
      expect(setup_user.first_run_setup_complete?).to be true
    end

    it "stays complete when the landed Epic is archived through the operator override" do
      repository = Factories.repository(user: setup_user)
      epic = Factories.epic(user: setup_user, repository: repository, state: "in_progress")
      epic.override_state!("done")
      expect(epic.reload.done_at).to be_present

      epic.override_state!("archived")
      expect(epic.reload.done_at).to be_present
      expect(setup_user.first_run_setup_complete?).to be true
    end

    it "does not count an Epic archived without ever landing" do
      repository = Factories.repository(user: setup_user)
      epic = Factories.epic(user: setup_user, repository: repository, state: "backlog")

      epic.archive!
      expect(epic.reload.state).to eq("archived")
      expect(setup_user.first_epic_landed?).to be false
      expect(setup_user.first_run_setup_complete?).to be false
    end

    it "counts a landed Epic the user owns but did not create" do
      creator = Factories.user
      repository = Factories.repository(user: creator)
      Factories.epic(user: creator, repository: repository, state: "done", owner_user: setup_user)

      expect(setup_user.first_epic_landed?).to be true
      expect(setup_user.first_run_setup_complete?).to be true
      expect(creator.first_epic_landed?).to be true
    end
  end

  describe "locale" do
    it "defaults to 'en' when not specified" do
      user = User.create!(attrs)
      expect(user.locale).to eq("en")
    end

    it "stores and retrieves a supported locale" do
      user = User.create!(attrs.merge(locale: "de"))
      expect(user.reload.locale).to eq("de")

      user.update!(locale: "la")
      expect(user.reload.locale).to eq("la")
    end

    it "rejects locales not in the allowed list" do
      user = User.new(attrs.merge(locale: "fr"))
      expect(user).not_to be_valid
      expect(user.errors[:locale]).to be_present
    end

    it "seeds a blank locale to 'en' via after_initialize" do
      user = User.new(attrs.merge(locale: ""))
      expect(user.locale).to eq("en")
      expect(user).to be_valid
    end

    it "seeds locale column in the database" do
      expect(User.column_names).to include("locale")
    end
  end
end
