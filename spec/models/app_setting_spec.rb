require "rails_helper"

RSpec.describe AppSetting do
  it ".current creates the singleton row on first call" do
    expect { AppSetting.current }.to change(AppSetting, :count).from(0).to(1)
  end

  it ".current returns the existing row on subsequent calls" do
    AppSetting.create!
    expect { AppSetting.current }.not_to change(AppSetting, :count)
  end

  describe "SYRUS_BOOT_POLLING_PAUSED seeding" do
    it "seeds polling paused on the first create when the env is truthy" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_BOOT_POLLING_PAUSED").and_return("1")

      expect(AppSetting.current.polling_paused).to be true
    end

    it "leaves polling running on the first create by default" do
      # Pin the env-absent precondition: the suite runs inside a backend
      # container whose compose env_file may export SYRUS_BOOT_POLLING_PAUSED=1
      # (a test-channel stack), which would otherwise seed this example paused.
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_BOOT_POLLING_PAUSED").and_return(nil)

      expect(AppSetting.current.polling_paused).to be false
    end

    it "treats an explicitly falsy env value as not paused" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_BOOT_POLLING_PAUSED").and_return("no")

      expect(AppSetting.current.polling_paused).to be false
    end

    # It seeds the DB row once; it must not force the value on an existing row,
    # so the operator can unpause a test stack from the admin console.
    it "does not re-pause an existing row even when the env is set" do
      AppSetting.current.update!(polling_paused: false)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_BOOT_POLLING_PAUSED").and_return("1")

      expect(AppSetting.current.polling_paused).to be false
    end
  end

  it ".signups_open? defaults to false" do
    expect(AppSetting.signups_open?).to be false
  end

  it ".signups_open? reflects the toggle" do
    AppSetting.current.update!(signups_open: true)
    expect(AppSetting.signups_open?).to be true
  end

  it ".grade_max_iterations defaults to 5 and reflects the setting" do
    expect(AppSetting.grade_max_iterations).to eq(5)

    AppSetting.current.update!(grade_max_iterations: 2)

    expect(AppSetting.grade_max_iterations).to eq(2)
  end

  it ".adversarial_review_rounds defaults to 0 and reflects the setting" do
    expect(AppSetting.adversarial_review_rounds).to eq(0)

    AppSetting.current.update!(adversarial_review_rounds: 2)

    expect(AppSetting.adversarial_review_rounds).to eq(2)
  end

  it "rejects grade_max_iterations above 10" do
    expect(AppSettingRegistry.fetch(:grade_max_iterations).max).to eq(10)

    setting = AppSetting.current
    setting.grade_max_iterations = 11

    expect(setting).not_to be_valid
    expect(setting.errors[:grade_max_iterations]).to include("must be less than or equal to 10")
  end

  it "rejects negative adversarial_review_rounds" do
    expect(AppSettingRegistry.fetch(:adversarial_review_rounds).min).to eq(0)

    setting = AppSetting.current
    setting.adversarial_review_rounds = -1

    expect(setting).not_to be_valid
    expect(setting.errors[:adversarial_review_rounds]).to include("must be greater than or equal to 0")
  end

  it ".video_retention_days returns the column value (default 7)" do
    expect(AppSetting.video_retention_days).to eq(7)

    AppSetting.current.update!(video_retention_days: 14)

    expect(AppSetting.video_retention_days).to eq(14)
  end

  it ".video_storage_budget_bytes converts the MB column to bytes (default 2048MB)" do
    expect(AppSetting.video_storage_budget_bytes).to eq(2048 * 1024 * 1024)

    AppSetting.current.update!(video_storage_budget_mb: 5)

    expect(AppSetting.video_storage_budget_bytes).to eq(5 * 1024 * 1024)
  end

  it ".video_storage_budget_bytes is 0 (unlimited) when the MB column is 0" do
    AppSetting.current.update!(video_storage_budget_mb: 0)

    expect(AppSetting.video_storage_budget_bytes).to eq(0)
  end

  it ".chat_coding_workspace_budget_bytes converts the MB column to bytes (default unlimited)" do
    expect(AppSetting.chat_coding_workspace_budget_bytes).to eq(0)

    AppSetting.current.update!(chat_coding_workspace_budget_mb: 20_000)

    expect(AppSetting.chat_coding_workspace_budget_bytes).to eq(20_000 * 1024 * 1024)
  end

  it "rejects a negative chat_coding_workspace_budget_mb but allows 0 (unlimited)" do
    setting = AppSetting.current

    setting.chat_coding_workspace_budget_mb = -1
    expect(setting).not_to be_valid

    setting.chat_coding_workspace_budget_mb = 0
    expect(setting).to be_valid
  end

  it "defaults workflow admission policy to whole_workflow and validates known policies" do
    setting = AppSetting.current

    expect(setting.workflow_admission_policy).to eq("whole_workflow")
    expect(AppSetting.workflow_admission_policy).to eq("whole_workflow")
    expect(AppSetting.workflow_admission_phase_aware?).to be(false)

    setting.workflow_admission_policy = "phase_aware"
    expect(setting).to be_valid

    setting.workflow_admission_policy = "bogus"
    expect(setting).not_to be_valid
    expect(setting.errors[:workflow_admission_policy]).to be_present
  end

  # Guard against the destructive-cutoff footgun: retention 0/negative would
  # make the prune cutoff land at/after now and purge every stored video.
  it "rejects a video_retention_days below 1" do
    setting = AppSetting.current

    [ 0, -1 ].each do |bad|
      setting.video_retention_days = bad
      expect(setting).not_to be_valid
      expect(setting.errors[:video_retention_days]).to be_present
    end

    setting.video_retention_days = 1
    expect(setting).to be_valid
  end

  it "rejects a negative video_storage_budget_mb but allows 0 (unlimited)" do
    setting = AppSetting.current

    setting.video_storage_budget_mb = -1
    expect(setting).not_to be_valid

    setting.video_storage_budget_mb = 0
    expect(setting).to be_valid
  end

  it "reports whether a GitHub App has been registered" do
    setting = AppSetting.current
    expect(setting.github_app_registered?).to be false

    setting.update!(github_app_id: 123)
    expect(setting.github_app_registered?).to be true
    expect(AppSetting.github_app_registered?).to be true
  end

  it "stores GitHub App ids beyond 32-bit integer range" do
    setting = AppSetting.current

    setting.update!(github_app_id: 9_876_543_210)

    expect(setting.reload.github_app_id).to eq(9_876_543_210)
  end

  it "encrypts GitHub App secrets at rest" do
    setting = AppSetting.current
    setting.update!(
      github_app_private_key_pem: "private-key-pem"
    )

    row = AppSetting.connection.select_one(
      "SELECT github_app_private_key_pem FROM app_settings WHERE id = #{setting.id}"
    )
    expect(row["github_app_private_key_pem"]).not_to include("private-key-pem")
    expect(setting.reload.github_app_private_key_pem).to eq("private-key-pem")
  end

  it ".proactive_rebase_commit_threshold defaults to 20 and reflects the setting" do
    expect(AppSetting.proactive_rebase_commit_threshold).to eq(20)

    AppSetting.current.update!(proactive_rebase_commit_threshold: 50)

    expect(AppSetting.proactive_rebase_commit_threshold).to eq(50)
  end

  it "rejects a proactive_rebase_commit_threshold below 1" do
    setting = AppSetting.current

    setting.proactive_rebase_commit_threshold = 0
    expect(setting).not_to be_valid
    expect(setting.errors[:proactive_rebase_commit_threshold]).to be_present

    setting.proactive_rebase_commit_threshold = 1
    expect(setting).to be_valid
  end

  it "rejects clearing non-secret settings" do
    setting = AppSetting.current

    expect {
      setting.clear_secret!("signups_open")
    }.to raise_error(ArgumentError, "Unknown secret: signups_open")
  end

  describe "mode" do
    it "defaults to 'advanced'" do
      expect(AppSetting.current.mode).to eq("advanced")
    end

    it ".mode returns the current mode" do
      AppSetting.current.update!(mode: "simple")
      expect(AppSetting.mode).to eq("simple")
    end

    it "#simple? returns true when mode is simple" do
      setting = AppSetting.current
      setting.update!(mode: "simple")
      expect(setting.simple?).to be true
      expect(setting.advanced?).to be false
    end

    it "#advanced? returns true when mode is advanced" do
      setting = AppSetting.current
      expect(setting.advanced?).to be true
      expect(setting.simple?).to be false
    end

    it ".simple? delegates to the singleton" do
      AppSetting.current.update!(mode: "simple")
      expect(AppSetting.simple?).to be true
      expect(AppSetting.advanced?).to be false
    end

    it ".advanced? delegates to the singleton" do
      expect(AppSetting.advanced?).to be true
      expect(AppSetting.simple?).to be false
    end

    it "rejects invalid mode values" do
      setting = AppSetting.current
      setting.mode = "turbo"
      expect(setting).not_to be_valid
      expect(setting.errors[:mode]).to include("is not included in the list")
    end

    it "accepts 'advanced' and 'simple' as valid modes" do
      setting = AppSetting.current
      AppSetting::MODES.each do |valid_mode|
        setting.mode = valid_mode
        expect(setting).to be_valid
      end
    end
  end

  describe "mode_configured?" do
    it "returns false when mode_configured_at is nil" do
      expect(AppSetting.mode_configured?).to be false
    end

    it "returns true once mode_configured_at is stamped" do
      AppSetting.current.update!(mode_configured_at: Time.current)
      expect(AppSetting.mode_configured?).to be true
    end
  end

  describe "telegram settings" do
    it ".telegram_bot_token returns nil when not set" do
      expect(AppSetting.telegram_bot_token).to be_nil
    end

    it ".telegram_bot_token returns the stored value" do
      AppSetting.current.update!(telegram_bot_token: "secret-token-123")
      expect(AppSetting.telegram_bot_token).to eq("secret-token-123")
    end

    it "encrypts telegram_bot_token at rest" do
      AppSetting.current.update!(telegram_bot_token: "my-secret-token")

      row = AppSetting.connection.select_one(
        "SELECT telegram_bot_token FROM app_settings WHERE id = #{AppSetting.current.id}"
      )
      expect(row["telegram_bot_token"]).not_to include("my-secret-token")
      expect(AppSetting.current.reload.telegram_bot_token).to eq("my-secret-token")
    end

    it ".telegram_update_offset defaults to 0" do
      expect(AppSetting.telegram_update_offset).to eq(0)
    end

    it ".telegram_update_offset reflects the stored value" do
      AppSetting.current.update!(telegram_update_offset: 99)
      expect(AppSetting.telegram_update_offset).to eq(99)
    end

    it "telegram_bot_token is a clearable secret" do
      expect(AppSetting.clearable_secrets).to include("telegram_bot_token")
    end

    it "clears telegram_bot_token via clear_secret!" do
      AppSetting.current.update!(telegram_bot_token: "some-token")
      AppSetting.current.clear_secret!("telegram_bot_token")
      expect(AppSetting.telegram_bot_token).to be_nil
    end
  end
end
