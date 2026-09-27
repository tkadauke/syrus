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

    repo_payload = described_class.new(user: user).as_json[:repositories].sole

    expect(repo_payload[:current][:id]).to eq(live.id)
    expect(repo_payload[:current][:latest_revision][:content_blocks].first.dig("payload", "text")).to eq("Live text")
    expect(repo_payload[:history].first[:id]).to eq(archived.id)
  end
end
