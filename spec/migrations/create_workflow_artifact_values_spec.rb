require "rails_helper"
require Rails.root.join("db/migrate/20261022080636_create_workflow_artifact_values")

RSpec.describe CreateWorkflowArtifactValues, :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  it "moves growth-bound keys out of an existing workflow row" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    iterations = [ [ { "output" => "grader output" } ] ]
    workflow.update_column(:artifacts, { "head_sha" => "abc123", "iterations" => iterations })

    described_class.new.backfill_artifacts

    workflow.reload
    expect(workflow.artifact("head_sha")).to eq("abc123")
    expect(workflow.artifact("iterations")).to eq(iterations)
    expect(workflow.attributes_before_type_cast.fetch("artifacts")).to eq('{"head_sha":"abc123"}')
    expect(workflow.workflow_artifact_values.pluck(:key)).to eq([ "iterations" ])
  end
end
