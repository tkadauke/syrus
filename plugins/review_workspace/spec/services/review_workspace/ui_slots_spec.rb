require "rails_helper"

RSpec.describe ReviewWorkspacePlugin::UiSlots do
  let!(:instance_admin) { Factories.user }
  let(:user) { Factories.user(global_role: "user") }
  let(:repository) { Factories.repository(user:, auto_merge_enabled: true) }

  it "advertises the actionable count on Job dashboards" do
    Factories.job_record(user:, repository:, state: "implemented")

    panel = described_class.ui_slots(
      slot: "dashboard.jobs.notice",
      context: { user:, subject: "job", accessible_jobs_scope: Job.all }
    ).sole

    expect(panel).to include(
      id: "review_workspace.ready_jobs",
      component: "review_workspace/ReviewDashboardNotice",
      cacheable: false,
      props: { count: 1 }
    )
  end

  it "does not contribute to unrelated dashboards or empty stacks" do
    context = { user:, accessible_jobs_scope: Job.all }

    expect(described_class.ui_slots(slot: "dashboard.jobs.notice", context: context.merge(subject: "epic"))).to eq([])
    expect(described_class.ui_slots(slot: "dashboard.jobs.notice", context: context.merge(subject: "job"))).to eq([])
  end

  it "counts only Jobs in the caller's accessible scope" do
    included = Factories.job_record(user:, repository:, state: "implemented")
    Factories.job_record(user:, repository:, state: "implemented")

    panel = described_class.ui_slots(
      slot: "dashboard.jobs.notice",
      context: { user:, subject: "job", accessible_jobs_scope: Job.where(id: included.id) }
    ).sole

    expect(panel.dig(:props, :count)).to eq(1)
  end
end
