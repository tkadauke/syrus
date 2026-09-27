require "rails_helper"

RSpec.describe OperatorBriefing::Payload do
  let(:user) { Factories.user }
  let!(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end

  it "seeds enabled subscriptions for visible repositories" do
    payload = described_class.new(user: user).as_json

    expect(payload[:subscriptions].map { |row| row[:repository][:slug] }).to include(repository.slug)
    expect(payload[:repositories].map { |row| row[:repository][:slug] }).to include(repository.slug)
  end

  it "serializes the live briefing and archived history" do
    live_job = Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low")
    live = OperatorBriefing::Briefing.create!(job: live_job, owner_user: user, repository: repository, window_start: 1.day.ago, window_end: Time.current)
    live.revisions.create!(
      revision_number: 1,
      generated_at: Time.current,
      content_blocks: [ { "kind" => "narrative", "payload" => { "text" => "Old live text" } } ]
    )
    live.revisions.create!(
      revision_number: 2,
      generated_at: Time.current,
      content_blocks: [ { "kind" => "narrative", "payload" => { "text" => "Live text" } } ]
    )

    archived_job = Job.create!(user: user, owner_user: user, repository: repository, kind: "briefing_generate", priority: "low")
    archived_job.close_with_reason!("briefing_superseded") if archived_job.may_close?
    archived = OperatorBriefing::Briefing.create!(job: archived_job, owner_user: user, repository: repository, window_start: 3.days.ago, window_end: 2.days.ago)
    archived.revisions.create!(
      revision_number: 1,
      generated_at: 2.days.ago,
      content_blocks: [ { "kind" => "narrative", "payload" => { "text" => "Old text" } } ]
    )

    expect_any_instance_of(OperatorBriefing::Briefing).not_to receive(:latest_revision)

    repo_payload = described_class.new(user: user).as_json[:repositories].sole

    expect(repo_payload[:current][:id]).to eq(live.id)
    expect(repo_payload[:current][:latest_revision][:revision_number]).to eq(2)
    expect(repo_payload[:current][:latest_revision][:content_blocks].first.dig("payload", "text")).to eq("Live text")
    expect(repo_payload[:history].first[:id]).to eq(archived.id)
  end

  it "computes repository activity status without per-repository generators" do
    quiet_repository = Factories.repository(user: user, owner: "acme", name: "quiet")
    active_repository = Factories.repository(user: user, owner: "acme", name: "active")
    OperatorBriefing::BriefingSubscription.seed_for_user!(user)

    [ quiet_repository, active_repository ].each do |repo|
      archived_job = Job.create!(user: user, owner_user: user, repository: repo, kind: "briefing_generate", priority: "low")
      archived_job.close_with_reason!("briefing_superseded") if archived_job.may_close?
      archived_job.update_columns(finished_at: 2.days.ago)
      OperatorBriefing::Briefing.create!(job: archived_job, owner_user: user, repository: repo, window_start: 3.days.ago, window_end: 2.days.ago)
    end
    Job.create!(user: user, owner_user: user, repository: active_repository, kind: "direct", priority: "low", issue_number: nil, created_at: 1.hour.ago, updated_at: 1.hour.ago)

    expect(OperatorBriefing::Generator).not_to receive(:new)

    statuses = described_class.new(user: user).as_json[:repositories].index_by { |row| row[:repository][:slug] }.transform_values { |row| row[:status][:kind] }

    expect(statuses.fetch(quiet_repository.slug)).to eq("no_activity")
    expect(statuses.fetch(active_repository.slug)).to eq("ready")
  end
end
