require "rails_helper"

RSpec.describe SdlcPipeline::History do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:filter) { SdlcPipeline::Filter.from_tree({ "and" => [] }, user: user) }
  let(:now) { Time.zone.parse("2026-10-31 12:00:00") }

  before do
    allow(RepoDeploymentStagesReader).to receive(:for_repository)
      .with(repository).and_return(double(stages: [ SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: nil, tag_pattern: nil) ]))
  end

  it "returns a checkpoint and ordered deltas reconstructed from durable facts" do
    job = Factories.job_record(repository: repository, user: user, state: "running", created_at: now - 3.days)
    job.update_columns(created_at: now - 3.days)
    StateTransition.create!(subject: job, from_state: "running", to_state: "implemented", source: "aasm", created_at: now - 2.days)
    StateTransition.create!(subject: job, from_state: "implemented", to_state: "landing", source: "aasm", created_at: now - 1.day)
    job.update_columns(state: "closed", landed_sha: "abc", finished_at: now - 2.hours)
    JobDeploymentStageStatus.create!(job: job, stage_name: "production", reached_at: now - 1.hour)

    payload = described_class.new(repository: repository, user: user, filter: filter, from: (now - 60.hours).iso8601, to: now.iso8601, now: now).call

    expect(payload.dig(:checkpoint, :placements).first).to include(job_id: job.id, stage: "implementing")
    expect(payload[:deltas].map { |delta| delta[:to_stage] }).to eq(%w[review landing landed deployment:production])
    expect(payload[:ticks]).to eq(payload[:deltas].map { |delta| delta[:at] })
    expect(payload[:traces].first[:segments]).to include(
      include(stage: "review", entered_at: (now - 2.days).iso8601, left_at: (now - 1.day).iso8601, dwell_seconds: 1.day.to_i)
    )
    expect(payload.dig(:accuracy, :message)).to include("Card metadata is current")
  end

  it "applies the cohort filter before constructing history" do
    included = Factories.job_record(repository: repository, user: user, state: "running", created_at: now - 2.days)
    included.update_columns(created_at: now - 2.days)
    Factories.job_record(repository: repository, user: user, state: "running", created_at: now - 2.days)
    selected = SdlcPipeline::Filter.from_tree({ "and" => [ { "field" => "job_id", "op" => "is", "value" => included.id } ] }, user: user)

    payload = described_class.new(repository: repository, user: user, filter: selected, from: (now - 1.day).iso8601, to: now.iso8601, now: now).call

    expect(payload.dig(:checkpoint, :placements).map { |placement| placement[:job_id] }).to eq([ included.id ])
  end

  it "keeps historical reconstruction query count constant for busy repositories" do
    100.times do |index|
      job = Factories.job_record(repository: repository, user: user, state: "running", issue_number: 500 + index)
      job.update_columns(created_at: now - 2.days)
    end
    queries = []
    callback = ->(_name, _start, _finish, _id, data) { queries << data[:sql] if data[:sql].match?(/\ASELECT/i) && data[:name] != "SCHEMA" }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.new(repository: repository, user: user, filter: filter, from: (now - 1.day).iso8601, to: now.iso8601, now: now).call
    end

    expect(queries.grep(/FROM ["`]?jobs/i).length).to eq(1)
    expect(queries.grep(/FROM ["`]?state_transitions/i).length).to eq(1)
    expect(queries.grep(/FROM ["`]?job_deployment_stage_statuses/i).length).to be <= 1
  end

  it "clamps reversed and future range boundaries" do
    payload = described_class.new(
      repository: repository, user: user, filter: filter,
      from: (now + 2.days).iso8601, to: (now + 1.day).iso8601, now: now
    ).call

    expect(payload[:from]).to eq(now.iso8601)
    expect(payload[:to]).to eq(now.iso8601)
  end

  it "reports an omitted cohort instead of silently treating it as complete" do
    stub_const("SdlcPipeline::History::MAX_JOBS", 2)
    3.times do |index|
      job = Factories.job_record(repository: repository, user: user, state: "running", issue_number: 900 + index)
      job.update_columns(created_at: now - 2.days + index.minutes)
    end

    payload = described_class.new(repository: repository, user: user, filter: filter, from: (now - 1.day).iso8601, to: now.iso8601, now: now).call

    expect(payload.dig(:accuracy, :status)).to eq("bounded")
    expect(payload.dig(:accuracy, :truncated)).to be(true)
    expect(payload.dig(:bounds, :included_jobs)).to eq(2)
    expect(payload.dig(:bounds, :omitted_jobs)).to eq(1)
  end

  it "shortens the reconstructable range when the delta bound is reached" do
    stub_const("SdlcPipeline::History::MAX_DELTAS", 1)
    job = Factories.job_record(repository: repository, user: user, state: "landing", created_at: now - 3.days)
    job.update_columns(created_at: now - 3.days)
    StateTransition.create!(subject: job, from_state: "running", to_state: "implemented", source: "aasm", created_at: now - 2.days)
    StateTransition.create!(subject: job, from_state: "implemented", to_state: "landing", source: "aasm", created_at: now - 1.day)

    payload = described_class.new(repository: repository, user: user, filter: filter, from: (now - 4.days).iso8601, to: now.iso8601, now: now).call

    expect(payload[:deltas].length).to eq(1)
    expect(Time.zone.parse(payload[:to])).to eq(Time.zone.parse(payload[:deltas].first[:at]))
    expect(payload[:ticks]).to eq([ payload[:deltas].first[:at] ])
    expect(payload.dig(:accuracy, :status)).to eq("bounded")
  end
end
