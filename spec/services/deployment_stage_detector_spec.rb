require "rails_helper"

RSpec.describe DeploymentStageDetector do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(repository: repository, landed_sha: "merge-sha", state: "closed") }
  let(:staging) { SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil) }
  let(:production) { SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: nil, tag_pattern: "deploy-prod-*") }
  let(:client) { instance_double(GithubClient) }

  it "records stages whose tag is identical to or ahead of the landed SHA" do
    allow(client).to receive(:list_tags).with(repository.slug).and_return([
      { name: "staging", sha: "staging-sha" },
      { name: "deploy-prod-20260730", sha: "prod-sha" }
    ])
    allow(client).to receive(:compare_commits).with(repository.slug, "merge-sha", "staging").and_return(status: "identical")
    allow(client).to receive(:compare_commits).with(repository.slug, "merge-sha", "deploy-prod-20260730").and_return(status: "ahead")

    count = described_class.new(repository: repository, deployment_stages: [ staging, production ], jobs: [ job ], client: client).call

    expect(count).to eq(2)
    expect(job.deployment_stage_statuses.order(:stage_name).pluck(:stage_name, :tag_sha)).to eq([
      [ "production", "prod-sha" ],
      [ "staging", "staging-sha" ]
    ])
  end

  it "skips missing tags, unreached compares, and already recorded stages" do
    reached_at = 1.day.ago.change(usec: 0)
    JobDeploymentStageStatus.create!(job: job, stage_name: "staging", reached_at: reached_at, tag_sha: "old")
    allow(client).to receive(:list_tags).with(repository.slug).and_return([
      { name: "staging", sha: "new" },
      { name: "deploy-prod-20260730", sha: "prod-sha" }
    ])
    expect(client).not_to receive(:compare_commits).with(repository.slug, "merge-sha", "staging")
    allow(client).to receive(:compare_commits).with(repository.slug, "merge-sha", "deploy-prod-20260730").and_return(status: "behind")

    count = described_class.new(repository: repository, deployment_stages: [ staging, production ], jobs: [ job ], client: client).call

    expect(count).to eq(0)
    status = job.deployment_stage_statuses.sole
    expect(status.stage_name).to eq("staging")
    expect(status.tag_sha).to eq("old")
    expect(status.reached_at).to eq(reached_at)
  end
end
