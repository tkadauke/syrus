require "rails_helper"

RSpec.describe JobDeploymentStageStatus do
  it "belongs to a job and enforces one row per job/stage" do
    job = Factories.job_record(landed_sha: "abc123", state: "closed")
    described_class.create!(job: job, stage_name: "staging", reached_at: Time.current, tag_sha: "tagsha")

    duplicate = described_class.new(job: job, stage_name: "staging", reached_at: Time.current)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:stage_name]).to include("has already been taken")
  end

  it "rechecks dependent open Jobs waiting on the recorded deployment stage" do
    user = Factories.user
    repository = Factories.repository(user: user)
    stage = SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil)
    production = SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: "production", tag_pattern: nil)
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repository).and_return(
      RepoDeploymentStagesReader::Result.new(stages: [ stage, production ], source: ".syrus.yml", note: nil)
    )

    upstream = Factories.job_record(user: user, repository: repository, issue_number: 10, state: "closed", closure_reason: "pr_merged")
    dependent = Factories.job_record(user: user, repository: repository, issue_number: 11, state: "queued")
    other_dependent = Factories.job_record(user: user, repository: repository, issue_number: 12, state: "queued")
    JobDependency.create!(
      job: dependent,
      depends_on_job: upstream,
      source: "manual",
      satisfaction_mode: "deployment_stage",
      required_deployment_stage_name: "staging"
    )
    JobDependency.create!(
      job: other_dependent,
      depends_on_job: upstream,
      source: "manual",
      satisfaction_mode: "deployment_stage",
      required_deployment_stage_name: "production"
    )

    expect_any_instance_of(Job).to receive(:start_pending_workflows_if_dependencies_satisfied!).once

    described_class.create!(job: upstream, stage_name: "staging", reached_at: Time.current)
  end
end
