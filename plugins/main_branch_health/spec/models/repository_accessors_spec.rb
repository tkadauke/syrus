require "rails_helper"

RSpec.describe MainBranchHealth::RepositoryAccessors do
  it "persists repository health settings and state outside the repositories table" do
    repository = Factories.repository(
      main_branch_health_enabled: true,
      main_branch_repair_enabled: true,
      ci_health: "broken",
      last_health_checked_sha: "abc123"
    )

    state = MainBranchHealth::RepositoryState.find_by!(repository_id: repository.id)
    expect(state).to have_attributes(
      main_branch_health_enabled: true,
      main_branch_repair_enabled: true,
      ci_health: "broken",
      last_health_checked_sha: "abc123"
    )
    expect(Repository.column_names).not_to include(*described_class::FIELDS.keys.map(&:to_s))
    expect(repository.reload).to have_attributes(ci_health: "broken", last_health_checked_sha: "abc123")
  end

  it "supports low-level state writes used by polling and workflow services" do
    repository = Factories.repository

    repository.update_columns(ci_health: "healthy", main_health_poll_error_streak: 2)

    expect(repository.reload).to have_attributes(ci_health: "healthy", main_health_poll_error_streak: 2)
  end

  it "finds broken enabled repositories through plugin-owned state" do
    broken = Factories.repository(main_branch_health_enabled: true, ci_health: "broken")
    Factories.repository(main_branch_health_enabled: false, ci_health: "broken")
    Factories.repository(main_branch_health_enabled: true, ci_health: "healthy", grader_health: "healthy")

    expect(Repository.with_broken_main_branch).to contain_exactly(broken)
  end

  it "preloads state once for repository collections" do
    repositories = Array.new(3) do |index|
      Factories.repository(main_branch_health_enabled: true, ci_health: index.zero? ? "broken" : "healthy")
    end
    statements = capture_sql do
      loaded = Repository.where(id: repositories.map(&:id)).to_a
      expect(loaded.map(&:ci_health)).to contain_exactly("broken", "healthy", "healthy")
    end

    state_selects = statements.grep(/SELECT .*FROM [`"]?main_branch_health_repository_states[`"]?/i)
    expect(state_selects.size).to eq(1)
  end

  it "does not query state once per repository in enabled batches" do
    repositories = Array.new(3) { Factories.repository(main_branch_health_enabled: true) }
    statements = capture_sql do
      expect(Repository.where(id: repositories.map(&:id)).with_main_branch_health_enabled.find_each.map(&:id))
        .to contain_exactly(*repositories.map(&:id))
    end

    state_selects = statements.grep(/SELECT .*FROM [`"]?main_branch_health_repository_states[`"]?/i)
    expect(state_selects.size).to be <= 2
  end

  it "persists the instance concern threshold outside app_settings" do
    AppSetting.current.update!(main_concern_report_threshold: 4)

    expect(AppSetting.column_names).not_to include("main_concern_report_threshold")
    expect(MainBranchHealth::Setting.current.main_concern_report_threshold).to eq(4)
    expect(AppSetting.current.reload.main_concern_report_threshold).to eq(4)
  end

  def capture_sql
    statements = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
