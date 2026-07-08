require "rails_helper"

RSpec.describe AppApi::ReadinessChecks do
  def with_env(vars)
    old_values = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def web_config_check_for(user)
    described_class.new(user).as_json.fetch(:checks).find { |check| check[:key] == "web_config" }
  end

  def github_app_check_for(user)
    described_class.new(user).as_json.fetch(:checks).find { |check| check[:key] == "github_app" }
  end

  before do
    AppSetting.current.update!(polling_paused: false, runs_paused: false)
    allow(Rails.env).to receive(:production?).and_return(true)
  end

  it "passes web config readiness without RAILS_MASTER_KEY when Active Record encryption works" do
    user = Factories.user

    with_env("RAILS_MASTER_KEY" => nil) do
      expect(web_config_check_for(user)).to include(
        status: "ok",
        message: "Rails booted and the primary database connection is available."
      )
    end
  end

  it "reports encryption remediation when Active Record encryption cannot be used" do
    user = Factories.user
    allow(ActiveRecord::Encryption.encryptor).to receive(:encrypt)
      .and_raise(ActiveRecord::Encryption::Errors::Configuration, "missing key")

    check = web_config_check_for(user)

    expect(check).to include(
      status: "error",
      message: "Rails is running, but Active Record encryption is not configured in the web environment.",
      remediation: "Set RAILS_MASTER_KEY or provide ACTIVE_RECORD_ENCRYPTION_* environment variables on every web and worker process."
    )
  end

  describe "GitHub App check" do
    def register_github_app(registered_at:)
      AppSetting.current.update!(
        github_app_id: 4242,
        github_app_slug: "operator-syrus",
        github_app_private_key_pem: "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----",
        github_app_registered_at: registered_at
      )
    end

    before do
      allow(GithubClient).to receive(:for_user).and_return(instance_double(GithubClient, readiness_check!: true))
    end

    it "passes when an active installation is linked" do
      register_github_app(registered_at: 2.days.ago)
      user = Factories.user
      Factories.installation(user: user)

      expect(github_app_check_for(user)).to include(
        status: "ok",
        message: "1 active GitHub App installation linked.",
        optional: true
      )
    end

    it "passes without installations when the current user has a personal access token" do
      register_github_app(registered_at: 2.days.ago)
      user = Factories.user(github_token: "ghp_current_user_token_1234567890abcd")

      expect(github_app_check_for(user)).to include(
        status: "ok",
        message: "No active GitHub App installations are linked yet; repositories fall back to a configured personal access token.",
        optional: true
      )
    end

    it "passes without installations when any user has a PAT and no repositories exist yet (fresh instance)" do
      register_github_app(registered_at: 2.days.ago)
      Factories.user(github_token: "ghp_teammate_token_1234567890abcdefgh")
      user = Factories.user(github_token: nil)

      expect(github_app_check_for(user)).to include(status: "ok", optional: true)
    end

    it "passes without installations when every active repository's owner has a PAT" do
      register_github_app(registered_at: 2.days.ago)
      owner = Factories.user(github_token: "ghp_repo_owner_token_1234567890abcdef")
      Factories.repository(user: owner)
      user = Factories.user(github_token: nil)

      expect(github_app_check_for(user)).to include(
        status: "ok",
        message: "No active GitHub App installations are linked yet; repositories fall back to a configured personal access token.",
        optional: true
      )
    end

    it "warns when a repository's owner lacks a PAT, even though an unrelated user has one" do
      # GithubClient.for falls back to the repository OWNER'S PAT — a PAT on a
      # user who owns no repositories would never be used, so it must not
      # satisfy the check while an ownerless-credential repository exists.
      register_github_app(registered_at: 2.days.ago)
      Factories.user(github_token: "ghp_unrelated_user_token_1234567890abcd")
      pat_less_owner = Factories.user(github_token: nil)
      Factories.repository(user: pat_less_owner)
      user = Factories.user(github_token: nil)

      expect(github_app_check_for(user)).to include(
        status: "warning",
        message: "GitHub App credentials exist, but no active installations are linked.",
        optional: true
      )
    end

    it "ignores archived repositories when deciding whether owner PATs cover the fallback" do
      register_github_app(registered_at: 2.days.ago)
      Factories.user(github_token: "ghp_teammate_token_1234567890abcdefgh")
      pat_less_owner = Factories.user(github_token: nil)
      Factories.repository(user: pat_less_owner, archived_at: 1.day.ago)
      user = Factories.user(github_token: nil)

      # Only the archived repo's owner lacks a PAT; archived repositories are
      # not polled, so the fresh-instance rule (any PAT) applies.
      expect(github_app_check_for(user)).to include(status: "ok", optional: true)
    end

    it "passes as pending sync when the App was registered very recently" do
      register_github_app(registered_at: 1.minute.ago)
      user = Factories.user(github_token: nil)

      expect(github_app_check_for(user)).to include(
        status: "ok",
        message: "GitHub App registered recently; the first installation sync may not have completed yet.",
        optional: true
      )
    end

    it "warns only when App creds exist, no installations are linked, and no user has a PAT" do
      register_github_app(registered_at: 2.days.ago)
      user = Factories.user(github_token: nil)

      expect(github_app_check_for(user)).to include(
        status: "warning",
        message: "GitHub App credentials exist, but no active installations are linked.",
        remediation: "Install the GitHub App on at least one GitHub owner, or use a personal access token.",
        optional: true
      )
    end

    it "still warns when the only installations were removed and the sync grace has passed" do
      register_github_app(registered_at: 2.days.ago)
      user = Factories.user(github_token: nil)
      Factories.installation(user: user, removed_at: 1.hour.ago)

      expect(github_app_check_for(user)).to include(status: "warning", optional: true)
    end
  end
end
