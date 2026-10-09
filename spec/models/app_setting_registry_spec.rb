require "rails_helper"

RSpec.describe AppSettingRegistry do
  it "covers every persisted AppSetting column except Rails bookkeeping" do
    registry_keys = described_class.definitions.map(&:key).map(&:to_s)
    # singleton_key isn't a configurable setting -- it's a DB-level constraint
    # column enforcing the single-row invariant, so it's bookkeeping like id.
    persisted_keys = AppSetting.column_names - %w[id created_at updated_at singleton_key]

    expect(registry_keys).to contain_exactly(*persisted_keys)
  end

  it "matches current AppSetting defaults" do
    setting = AppSetting.new

    described_class.definitions.each do |definition|
      expect(setting.public_send(definition.key)).to eq(definition.default)
    end
  end

  it "exposes validation and zero-semantics metadata for integer settings" do
    expect(described_class.fetch(:grade_max_iterations).numericality_options).to include(
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 10
    )
    expect(described_class.fetch(:video_storage_budget_mb).zero_means).to eq("Size cap is disabled; time-based retention still applies.")
    expect(described_class.fetch(:max_concurrent_agent_runs).zero_means).to include("No global cap")
    expect(described_class.fetch(:max_job_failures).min).to eq(1)
    expect(described_class.fetch(:max_job_failures).zero_means).to be_nil
    expect(described_class.fetch(:merge_train_max_size).min).to eq(1)
    expect(described_class.fetch(:user_daily_spend_budget_usd).default).to eq(0)
    expect(described_class.fetch(:user_daily_spend_budget_usd).zero_means).to include("No per-user USD spend budget")
  end

  it "declares the current admin settings payload metadata" do
    expect(described_class.admin_editable_keys).to eq([
      :grade_max_iterations,
      :adversarial_review_rounds,
      :max_job_failures,
      :rebase_failure_cooldown_minutes,
      :merge_train_failure_policy,
      :merge_train_max_size,
      :signups_open,
      :beta_mode_enabled,
      :telegram_bot_handle,
      :telegram_bot_token,
      :discord_bot_token,
      :report_issue_repo_slug,
      :max_concurrent_agent_runs,
      :user_daily_spend_budget_usd,
      :proactive_rebase_commit_threshold,
      :show_work_unit_debug,
      :workflow_admission_control_enabled,
      :workflow_admission_policy,
      :video_retention_days,
      :video_storage_budget_mb,
      :chat_coding_workspace_budget_mb,
      :retention_available_space_override_gb,
      :main_concern_report_threshold,
      *RetentionPolicyRegistry.definitions.map(&:setting_key),
      *RetentionPolicyRegistry.archive_app_setting_definitions.map(&:key)
    ])

    expect(described_class.metadata_for([ :proactive_rebase_commit_threshold ])).to eq([
      {
        key: "proactive_rebase_commit_threshold",
        type: "integer",
        default: 20,
        category: "Instance operations",
        operational_meaning: "Commits-behind threshold that triggers proactive PR rebase maintenance while mergeability is still clean.",
        min: 1,
        admin_editable: true,
        secret: false,
        surface: "admin_settings"
      }
    ])
  end

  it "declares every setting reachable from an admin surface" do
    expect(described_class.admin_settings_keys).to match_array(described_class.admin_editable_keys)
    expect(described_class.admin_console_keys).to contain_exactly(
      :merge_train_enabled,
      :polling_paused,
      :runs_paused
    )
    expect(described_class.admin_settings_keys & described_class.admin_console_keys).to be_empty
  end

  it "folds RetentionPolicyRegistry entries in as admin-editable integer settings with a 0=infinite floor" do
    RetentionPolicyRegistry.definitions.each do |retention_definition|
      definition = described_class.fetch(retention_definition.setting_key)

      expect(definition.type).to eq(:integer)
      expect(definition.default).to eq(retention_definition.default_value)
      expect(definition.admin_editable).to be true
      expect(definition.numericality_options).to include(greater_than_or_equal_to: 0)
    end
  end

  it "folds every archivable RetentionPolicyRegistry entry in as an admin-editable boolean, default false" do
    RetentionPolicyRegistry.definitions.select(&:archivable).each do |retention_definition|
      definition = described_class.fetch(retention_definition.archive_setting_key)

      expect(definition.type).to eq(:boolean)
      expect(definition.default).to eq(false)
      expect(definition.admin_editable).to be true
    end
  end
end
