require "rails_helper"

RSpec.describe PollAllDeploymentStagesJob do
  it "enqueues one repository poll for active repositories with deployment stages configured" do
    configured = Factories.repository
    unconfigured = Factories.repository
    archived = Factories.repository
    archived.archive!

    enabled_plan = RepoDeploymentStagesReader::Result.new(stages: [ SyrusYml::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil) ], source: ".syrus.yml", note: nil)
    disabled_plan = RepoDeploymentStagesReader::Result.new(stages: [], source: "none", note: "no deployment_stages configured")
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(configured).and_return(enabled_plan)
    allow(RepoDeploymentStagesReader).to receive(:for_repository).with(unconfigured).and_return(disabled_plan)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollRepositoryDeploymentStagesJob).once.with(configured.id)
  end

  it "does nothing when polling is globally paused" do
    allow(AppSetting).to receive(:polling_paused?).and_return(true)
    Factories.repository

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollRepositoryDeploymentStagesJob)
  end
end
