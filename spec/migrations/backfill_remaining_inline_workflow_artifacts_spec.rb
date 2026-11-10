require "rails_helper"
require Rails.root.join("db/migrate/20261110164233_backfill_remaining_inline_workflow_artifacts")

RSpec.describe BackfillRemainingInlineWorkflowArtifacts, :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:connection) { ActiveRecord::Base.connection }

  # The column is dropped by a later migration, so recreate it for the
  # duration of the example to represent a pre-drop database.
  around do |example|
    connection.add_column :workflows, :artifacts, :text unless connection.column_exists?(:workflows, :artifacts)
    Workflow.reset_column_information
    begin
      example.run
    ensure
      connection.remove_column :workflows, :artifacts if connection.column_exists?(:workflows, :artifacts)
      Workflow.reset_column_information
    end
  end

  it "copies inline-only keys, keeps existing side-table values, and is idempotent" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    empty = Workflow.create!(job: job, trigger_kind: "initial")
    connection.execute("UPDATE workflows SET artifacts = '#{JSON.generate("only_inline" => { "a" => 1 }, "both" => "stale")}' WHERE id = #{workflow.id}")
    workflow.workflow_artifact_values.create!(key: "both", value: "current")

    2.times { described_class.new.up }

    expect(Workflow.find(workflow.id).artifacts).to eq("only_inline" => { "a" => 1 }, "both" => "current")
    expect(WorkflowArtifactValue.where(workflow_id: workflow.id).count).to eq(2)
    expect(empty.reload.artifacts).to eq({})
  end
end
