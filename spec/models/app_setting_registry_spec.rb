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
  end

  it "declares the current admin settings payload metadata" do
    expect(described_class.admin_editable_keys).to eq([
      :grade_max_iterations,
      :adversarial_review_rounds,
      :security_review_rounds,
      :max_job_failures,
      :rebase_failure_cooldown_minutes,
      :contained_chat_execution,
      :merge_train_failure_policy,
      :merge_train_max_size,
      :merge_train_multisect_section_width,
      :signups_open,
      :ui_engagement_telemetry_enabled,
      :beta_mode_enabled,
      :telegram_bot_handle,
      :telegram_bot_token,
      :discord_bot_token,
      :report_issue_repo_slug,
      :max_concurrent_agent_runs,
      :prepared_layer_cache_gb,
      :max_in_flight_workflows,
      :repository_full_poll_interval_hours,
      :proactive_rebase_commit_threshold,
      :show_work_unit_debug,
      :workflow_admission_control_enabled,
      :workflow_admission_policy,
      :video_retention_days,
      :video_storage_budget_mb,
      :chat_coding_workspace_budget_mb,
      :retention_available_space_override_gb,
      :workflow_step_resource_profile_input_retention_days,
      :main_concern_report_threshold
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
      :polling_paused,
      :runs_paused
    )
    expect(described_class.admin_settings_keys & described_class.admin_console_keys).to be_empty
  end

  it "does not include row-retention policy values" do
    expect(described_class.definitions.map(&:key)).not_to include(
      :job_log_retention_days,
      :job_log_archive_before_delete
    )
  end
end
