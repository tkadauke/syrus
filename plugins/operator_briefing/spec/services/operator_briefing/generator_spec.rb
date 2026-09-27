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
    expect(result.job).to be_investigation
    expect(result.briefing).to have_attributes(owner_user: user, repository: repository, job: result.job)
    expect(WorkUnits::Launcher).to have_received(:create_and_start!).with(
      kind: "briefing_generate",
      job: result.job,
      agent_provider: nil
    )
  end

  it "starts another generation workflow on the current live briefing for on-demand regeneration" do
    first = described_class.generate!(user: user, repository: repository, mode: :on_demand)

    second = described_class.generate!(user: user, repository: repository, mode: :on_demand)

    expect(second.job).to eq(first.job)
    expect(second.briefing).to eq(first.briefing)
    expect(first.job.reload).not_to be_closed
    expect(WorkUnits::Launcher).to have_received(:create_and_start!).with(
      kind: "briefing_generate",
      job: first.job,
      agent_provider: nil
    ).twice
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

  it "skips scheduled generation when the current live briefing already covers the latest activity" do
    now = Time.zone.parse("2026-09-27 12:00:00 UTC")

    travel_to(now - 3.days) do
      Job.create!(user: user, owner_user: user, repository: repository, kind: "direct", issue_number: nil, issue_title: "Already covered", priority: "low")
    end
    live_job = Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low")
    OperatorBriefing::Briefing.create!(
      job: live_job,
      repository: repository,
      owner_user: user,
      window_start: now - 4.days,
      window_end: now - 2.days
    )

    result = travel_to(now) { described_class.generate!(user: user, repository: repository, mode: :scheduled, now: now) }

    expect(result).to be_skipped
    expect(result.reason).to eq("no_activity")
    expect(live_job.reload).not_to be_closed
    expect(OperatorBriefing::Briefing.count).to eq(1)
  end

  it "supersedes the current live briefing when scheduled activity is newer than its window" do
    now = Time.zone.parse("2026-09-27 12:00:00 UTC")
    previous_window_end = now - 2.days
    live_job = Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low")
    OperatorBriefing::Briefing.create!(
      job: live_job,
      repository: repository,
      owner_user: user,
      window_start: now - 4.days,
      window_end: previous_window_end
    )
    travel_to(now - 1.day) do
      Job.create!(user: user, owner_user: user, repository: repository, kind: "direct", issue_number: nil, issue_title: "Fresh activity", priority: "low")
    end

    result = travel_to(now) { described_class.generate!(user: user, repository: repository, mode: :scheduled, now: now) }

    expect(result).to be_created
    expect(result.job).not_to eq(live_job)
    expect(live_job.reload).to be_closed
    expect(live_job.closure_reason).to eq("briefing_superseded")
    expect(result.briefing.window_start).to eq(previous_window_end)
  end
end
