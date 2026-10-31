require "rails_helper"

RSpec.describe SdlcPipeline::Projection do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:deployment_stages) {
    [
      SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: nil, tag_pattern: nil),
      SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: nil, tag_pattern: nil)
    ]
  }

  before do
    allow(RepoDeploymentStagesReader).to receive(:for_repository)
      .with(repository).and_return(double(stages: deployment_stages))
  end

  it "places each Job at its furthest proven mutually exclusive stage with evidence" do
    epic = Factories.epic(repository: repository, user: user, title: "Release train")
    Factories.job_record(repository: repository, user: user, epic: epic, state: "implemented", issue_title: "Review me")
    landed = Factories.job_record(repository: repository, user: user, state: "closed", landed_sha: "abc123", finished_at: 1.hour.ago, issue_title: "Ship me")
    JobDeploymentStageStatus.create!(job: landed, stage_name: "staging", reached_at: 30.minutes.ago, tag_sha: "abc123")
    JobDeploymentStageStatus.create!(job: landed, stage_name: "production", reached_at: 10.minutes.ago, tag_sha: "abc123")

    payload = described_class.new(repository: repository, user: user).call

    expect(payload[:stages].find { |stage| stage[:key] == "review" }[:total]).to eq(1)
    production = payload[:stages].find { |stage| stage[:key] == "deployment:production" }
    expect(production[:total]).to eq(1)
    expect(production[:highlighted_items].first[:evidence]).to include(
      type: "deployment_stage", stage_name: "production", tag_sha: "abc123"
    )
    expect(payload[:stages].sum { |stage| stage[:total] }).to eq(2)
    expect(payload[:groups]).to include(include(label: "Release train", total: 1), include(key: "ungrouped", total: 1))
  end

  it "bounds highlights, terminal history, and drill-down pages" do
    7.times { |index| Factories.job_record(repository: repository, user: user, state: "running", issue_number: 100 + index) }
    55.times do |index|
      Factories.job_record(
        repository: repository, user: user, state: "closed", landed_sha: "sha#{index}",
        issue_number: 200 + index, finished_at: index.minutes.ago, updated_at: index.minutes.ago
      )
    end

    payload = described_class.new(repository: repository, user: user, stage: "implementing", page: 2, limit: 3).call
    implementing = payload[:stages].find { |stage| stage[:key] == "implementing" }

    expect(implementing[:highlighted_items].length).to eq(5)
    expect(payload[:stages].find { |stage| stage[:key] == "landed" }[:total]).to eq(50)
    expect(payload[:drill_down]).to include(stage: "implementing", page: 2, limit: 3, total: 7, next_page: 3)
    expect(payload[:drill_down][:items].length).to eq(3)
  end

  it "excludes terminal Jobs without successful completion evidence" do
    Factories.job_record(
      repository: repository,
      user: user,
      state: "closed",
      closure_reason: "cancelled",
      finished_at: 1.hour.ago,
      updated_at: 1.hour.ago
    )

    payload = described_class.new(repository: repository, user: user).call

    expect(payload[:stages].sum { |stage| stage[:total] }).to eq(0)
    expect(payload[:groups]).to be_empty
  end

  it "keeps projection query count constant as repository size grows" do
    100.times { |index| Factories.job_record(repository: repository, user: user, state: "running", issue_number: 500 + index) }
    queries = []
    callback = ->(_name, _start, _finish, _id, data) {
      queries << data[:sql] if data[:sql].match?(/\ASELECT/i) && data[:name] != "SCHEMA"
    }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.new(repository: repository, user: user).call
    end

    expect(queries.grep(/FROM [\"`]?jobs/i).length).to be <= 2
    expect(queries.grep(/FROM [\"`]?epics/i).length).to be <= 2
    expect(queries.grep(/FROM [\"`]?job_deployment_stage_statuses/i).length).to be <= 2
  end
end
