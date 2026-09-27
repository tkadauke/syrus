require "rails_helper"

RSpec.describe OperatorBriefing::Generator do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    allow(WorkUnits::Launcher).to receive(:create_and_start!) do |kind:, job:, **|
      OperatorBriefing::Workflow.instantiate(job: job)
    end
  end

  it "skips a scheduled briefing when there is no repository activity" do
    result = described_class.generate!(user: user, repository: repository, mode: :scheduled)

    expect(result).to be_skipped
    expect(result.reason).to eq("no_activity")
    expect(OperatorBriefing::Briefing.count).to eq(0)
  end

  it "creates an on-demand briefing regardless of activity" do
    result = described_class.generate!(user: user, repository: repository, mode: :on_demand)

    expect(result).to be_created
    expect(result.job.kind).to eq("briefing_generate")
    expect(result.briefing).to have_attributes(owner_user: user, repository: repository, job: result.job)
    expect(WorkUnits::Launcher).to have_received(:create_and_start!).with(
      kind: "briefing_generate",
      job: result.job,
      agent_provider: nil
    )
  end

  it "closes the previous live briefing when a new one supersedes it" do
    first = described_class.generate!(user: user, repository: repository, mode: :on_demand)

    second = described_class.generate!(user: user, repository: repository, mode: :on_demand)

    expect(first.job.reload).to be_closed
    expect(first.job.closure_reason).to eq("briefing_superseded")
    expect(second.job.reload).not_to be_closed
  end

  it "creates a scheduled briefing when activity happened since the last closed briefing" do
    closed_job = Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low")
    closed_job.close_with_reason!("briefing_superseded") if closed_job.may_close?
    OperatorBriefing::Briefing.create!(
      job: closed_job,
      repository: repository,
      owner_user: user,
      window_start: 2.days.ago,
      window_end: 1.day.ago
    )
    Job.create!(user: user, owner_user: user, repository: repository, kind: "direct", issue_number: nil, issue_title: "Changed", priority: "low")

    result = described_class.generate!(user: user, repository: repository, mode: :scheduled)

    expect(result).to be_created
  end
end
