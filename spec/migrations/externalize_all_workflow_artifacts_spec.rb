require "rails_helper"
require Rails.root.join("db/migrate/20261104195733_externalize_all_workflow_artifacts")

RSpec.describe ExternalizeAllWorkflowArtifacts, :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  it "moves every inline key and preserves an existing external value" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_column(:artifacts, { "unknown" => { "large" => true }, "existing" => "stale" })
    workflow.workflow_artifact_values.create!(key: "existing", value: "current")

    described_class.new.up

    workflow.reload
    expect(workflow.attributes_before_type_cast.fetch("artifacts")).to eq("{}")
    expect(workflow.artifacts).to eq("unknown" => { "large" => true }, "existing" => "current")
  end
end
