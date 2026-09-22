require "rails_helper"

RSpec.describe DeploymentStageDetector do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(repository: repository, landed_sha: "merge-sha", state: "closed") }
  let(:staging) { SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil) }
  let(:production) { SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: nil, tag_pattern: "deploy-prod-*") }
  let(:content) { instance_double(RepositoryContent::Reader) }
  let(:staging_revision) { RepositoryContent::Revision.new(id: "staging-sha", ref: "staging") }
  let(:production_ref) { RepositoryContent::Ref.new(name: "deploy-prod-20260730", revision_id: "prod-sha") }

  it "records stages whose tag is identical to or ahead of the landed SHA" do
    allow(content).to receive(:resolve).with("staging", max_age: 0).and_return(staging_revision)
    allow(content).to receive(:refs).with(pattern: "deploy-prod-*", max_age: 0).and_return([ production_ref ])
    allow(content).to receive(:revision) { |id| RepositoryContent::Revision.new(id: id) }
    allow(content).to receive(:relation).and_return(:identical, :ahead)

    count = described_class.new(repository: repository, deployment_stages: [ staging, production ], jobs: [ job ], content: content).call

    expect(count).to eq(2)
    expect(job.deployment_stage_statuses.order(:stage_name).pluck(:stage_name, :tag_sha)).to eq([
      [ "production", "prod-sha" ],
      [ "staging", "staging-sha" ]
    ])
  end

  it "skips missing tags, unreached compares, and already recorded stages" do
    reached_at = 1.day.ago.change(usec: 0)
    JobDeploymentStageStatus.create!(job: job, stage_name: "staging", reached_at: reached_at, tag_sha: "old")
    allow(content).to receive(:refs).with(pattern: "deploy-prod-*", max_age: 0).and_return([ production_ref ])
    allow(content).to receive(:revision) { |id| RepositoryContent::Revision.new(id: id) }
    allow(content).to receive(:relation).and_return(:behind)

    count = described_class.new(repository: repository, deployment_stages: [ staging, production ], jobs: [ job ], content: content).call

    expect(count).to eq(0)
    status = job.deployment_stage_statuses.sole
    expect(status.stage_name).to eq("staging")
    expect(status.tag_sha).to eq("old")
    expect(status.reached_at).to eq(reached_at)
  end

  it "records an exact tag SHA without comparing commits" do
    allow(content).to receive(:resolve).with("staging", max_age: 0).and_return(RepositoryContent::Revision.new(id: "merge-sha", ref: "staging"))
    expect(content).not_to receive(:relation)

    count = described_class.new(repository: repository, deployment_stages: [ staging ], jobs: [ job ], content: content).call

    expect(count).to eq(1)
    expect(job.deployment_stage_statuses.sole).to have_attributes(stage_name: "staging", tag_sha: "merge-sha")
  end

  it "batches the detected-stage lookup instead of querying once per job" do
    other_job = Factories.job_record(repository: repository, landed_sha: "merge-sha", state: "closed")
    JobDeploymentStageStatus.create!(job: job, stage_name: "staging", reached_at: 1.day.ago, tag_sha: "old")
    JobDeploymentStageStatus.create!(job: other_job, stage_name: "staging", reached_at: 1.day.ago, tag_sha: "old")
    expect(content).not_to receive(:resolve)

    query_count = 0
    counter = ->(*, payload) { query_count += 1 if payload[:sql].match?(/\ASELECT/i) && payload[:sql].include?("job_deployment_stage_statuses") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      described_class.new(repository: repository, deployment_stages: [ staging ], jobs: [ job, other_job ], content: content).call
    end

    expect(query_count).to eq(1)
  end

  it "reuses commit comparison results for jobs landed at the same SHA" do
    other_job = Factories.job_record(repository: repository, landed_sha: "merge-sha", state: "closed")
    allow(content).to receive(:resolve).with("staging", max_age: 0).and_return(staging_revision)
    allow(content).to receive(:revision) { |id| RepositoryContent::Revision.new(id: id) }
    expect(content).to receive(:relation).once.and_return(:ahead)

    count = described_class.new(repository: repository, deployment_stages: [ staging ], jobs: [ job, other_job ], content: content).call

    expect(count).to eq(2)
    expect(JobDeploymentStageStatus.where(job: [ job, other_job ]).pluck(:job_id, :stage_name, :tag_sha)).to match_array([
      [ job.id, "staging", "staging-sha" ],
      [ other_job.id, "staging", "staging-sha" ]
    ])
  end
end
