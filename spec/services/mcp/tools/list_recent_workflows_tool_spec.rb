require "rails_helper"

RSpec.describe Mcp::Tools::ListRecentWorkflowsTool do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:context_run) { Factories.run(repository: repo, user: user) }
  let(:target_job) { Factories.job_record(repository: repo, user: user, issue_number: 7) }
  let(:target_workflow) do
    Workflow.create!(job: target_job, trigger_kind: "initial", started_at: 1.hour.ago, finished_at: 30.minutes.ago)
  end

  before { target_workflow }

  def call
    described_class.call(server_context: { run: context_run })
  end

  def workflow_payload(response)
    payload = JSON.parse(response.content.first[:text])
    payload["workflows"].find { |w| w["id"] == target_workflow.id }
  end

  it "includes a workflow's WorkflowWarning rows in the payload" do
    WorkflowWarnings.record!(
      workflow: target_workflow,
      kind: "grader_side_effect",
      severity: "medium",
      title: "Grader left changes",
      evidence: { "grader_name" => "tests", "changed_files" => [ "foo.txt" ] }
    )

    payload = workflow_payload(call)

    expect(payload["warnings"].size).to eq(1)
    expect(payload["warnings"].first).to include(
      "kind" => "grader_side_effect",
      "severity" => "medium",
      "state" => "pending",
      "created_job_id" => nil
    )
    expect(payload["warnings"].first["evidence"]).to eq({ "grader_name" => "tests", "changed_files" => [ "foo.txt" ] })
  end

  it "returns an empty warnings array when there are none" do
    payload = workflow_payload(call)

    expect(payload["warnings"]).to eq([])
  end

  it "redacts secrets in warning evidence" do
    WorkflowWarnings.record!(
      workflow: target_workflow,
      kind: "grader_side_effect",
      title: "leak",
      evidence: { "command" => "curl https://x-access-token:abc123@github.com/acme/widgets.git" }
    )

    payload = workflow_payload(call)

    expect(payload["warnings"].first["evidence"]["command"]).not_to include("abc123")
  end
end
