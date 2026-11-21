require "rails_helper"

RSpec.describe ReviewWorkspacePlugin::UiSlots do
  let!(:instance_admin) { Factories.user }
  let(:user) { Factories.user(global_role: "user") }
  let(:repository) { Factories.repository(user:, auto_merge_enabled: true) }

  it "advertises the actionable count on Job dashboards" do
    Factories.job_record(user:, repository:, state: "implemented")

    panel = described_class.ui_slots(slot: "dashboard.jobs.notice", context: { user:, subject: "job" }).sole

    expect(panel).to include(
      id: "review_workspace.ready_jobs",
      component: "review_workspace/ReviewDashboardNotice",
      cacheable: false,
      props: { count: 1 }
    )
  end

  it "does not contribute to unrelated dashboards or empty stacks" do
    expect(described_class.ui_slots(slot: "dashboard.jobs.notice", context: { user:, subject: "epic" })).to eq([])
    expect(described_class.ui_slots(slot: "dashboard.jobs.notice", context: { user:, subject: "job" })).to eq([])
  end
end
