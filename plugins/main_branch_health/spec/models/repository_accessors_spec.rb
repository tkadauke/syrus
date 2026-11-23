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

  it "persists the instance concern threshold outside app_settings" do
    AppSetting.current.update!(main_concern_report_threshold: 4)

    expect(AppSetting.column_names).not_to include("main_concern_report_threshold")
    expect(MainBranchHealth::Setting.current.main_concern_report_threshold).to eq(4)
    expect(AppSetting.current.reload.main_concern_report_threshold).to eq(4)
  end
end
