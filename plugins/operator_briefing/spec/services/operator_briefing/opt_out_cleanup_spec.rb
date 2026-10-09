require "rails_helper"

RSpec.describe OperatorBriefing::OptOutCleanup do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end

  it "cancels active briefing work for the disabled user and repository" do
    job = Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low")
    briefing = OperatorBriefing::Briefing.create!(job: job, owner_user: user, repository: repository, window_start: 1.day.ago, window_end: Time.current)
    workflow = OperatorBriefing::Workflow.instantiate(job: job)
    unit = attach_work_unit(workflow, state: "blocked", blocked_reason: "provider_availability")
    subscription = OperatorBriefing::BriefingSubscription.create!(user: user, repository: repository, enabled: false)

    described_class.cancel_for_subscription!(subscription)

    expect(briefing.job.reload).to be_closed
    expect(briefing.job.closure_reason).to eq("cancelled")
    expect(unit.reload).to be_cancelled
  end
end
