require "rails_helper"

RSpec.describe PollRepositoryDeploymentStagesJob do
  let(:repository) { Factories.repository }
  let(:staging) { SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil) }
  let(:production) { SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: "production", tag_pattern: nil) }
  let(:plan) { RepoDeploymentStagesReader::Result.new(stages: [ staging, production ], source: ".syrus.yml", note: nil) }

  it "passes landed jobs with at least one undetected stage to the detector" do
    missing_all = Factories.job_record(repository: repository, landed_sha: "sha1", state: "closed", issue_number: 100)
    missing_one = Factories.job_record(repository: repository, landed_sha: "sha2", state: "closed", issue_number: 101)
    obsolete_only = Factories.job_record(repository: repository, landed_sha: "sha4", state: "closed", issue_number: 104)
    complete = Factories.job_record(repository: repository, landed_sha: "sha3", state: "closed", issue_number: 102)
    stale = Factories.job_record(repository: repository, landed_sha: "sha5", state: "closed", issue_number: 105)
    Factories.job_record(repository: repository, landed_sha: nil, state: "closed", issue_number: 103)
    stale.update_column(:finished_at, 30.days.ago)

    JobDeploymentStageStatus.create!(job: missing_one, stage_name: "staging", reached_at: Time.current)
    JobDeploymentStageStatus.create!(job: obsolete_only, stage_name: "old_stage", reached_at: Time.current)
    JobDeploymentStageStatus.create!(job: complete, stage_name: "staging", reached_at: Time.current)
    JobDeploymentStageStatus.create!(job: complete, stage_name: "production", reached_at: Time.current)
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repository).and_return(plan)

    detector = instance_double(DeploymentStageDetector, call: 0)
    expect(DeploymentStageDetector).to receive(:new) do |args|
      expect(args[:repository]).to eq(repository)
      expect(args[:deployment_stages]).to eq([ staging, production ])
      expect(args[:jobs]).to contain_exactly(missing_all, missing_one, obsolete_only)
      expect(args[:jobs]).not_to include(stale)
      detector
    end

    described_class.perform_now(repository.id)
  end

  it "caps each poll to a bounded number of landed jobs" do
    stub_const("#{described_class}::MAX_JOBS_PER_POLL", 2)
    jobs = 3.times.map do |index|
      Factories.job_record(
        repository: repository,
        landed_sha: "sha#{index}",
        finished_at: index.minutes.ago,
        state: "closed",
        issue_number: 200 + index
      )
    end
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repository).and_return(plan)

    detector = instance_double(DeploymentStageDetector, call: 0)
    expect(DeploymentStageDetector).to receive(:new) do |args|
      expect(args[:jobs]).to eq([ jobs[0], jobs[1] ])
      detector
    end

    described_class.perform_now(repository.id)
  end

  it "returns when deployment stages are not configured" do
    disabled = RepoDeploymentStagesReader::Result.new(stages: [], source: "none", note: "no deployment_stages configured")
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(repository).and_return(disabled)

    expect(DeploymentStageDetector).not_to receive(:new)
    described_class.perform_now(repository.id)
  end
end
