require "rails_helper"

RSpec.describe AgentInsights::Tools::ListRecentWorkflowsTool do
  before { PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: true, disableable: true) }

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

  it "preloads artifact values once for a page of workflows" do
    listed_ids = 2.times.map do |index|
      workflow = Workflow.create!(
        job: Factories.job_record(repository: repo, user: user),
        trigger_kind: "initial",
        finished_at: (index + 1).hours.ago,
        artifacts: { "summary" => "Summary #{index}" }
      )
      workflow.id
    end
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload unless payload[:cached] || payload[:name] == "SCHEMA"
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { call }

    targeted_reads = queries.select do |payload|
      next false unless payload[:sql].match?(/SELECT .* FROM [`"]?workflow_artifact_values[`"]?.*workflow_id[`"]?\s*=\s*/i)

      bind_values = Array(payload[:binds]).map { |bind| bind.value_for_database }
      (bind_values & listed_ids).any?
    end
    expect(targeted_reads).to be_empty
  end

  # Regression: eager-loading full Run rows (prompts, diffs) for a page of
  # Workflows with hundreds of Steps exhausted the worker serving the call; it
  # was killed mid-call, and every Run on it failed as worker_died.
  it "never loads full Run rows, only the columns the payload shows" do
    step = Step.create!(workflow: target_workflow, kind: "implement", position: 0)
    step.runs.create!(job: target_job, trigger_kind: "initial", state: "succeeded", agent_summary: "did it", prompt: "x" * 10_000)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] unless payload[:cached] || payload[:name] == "SCHEMA" }

    response = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { call }

    # The listing must never select a Run's heavy columns -- not as `runs.*`
    # and not as the aliased columns of an eager-loading JOIN.
    expect(queries.grep(/[`"]?runs[`"]?\.[`"]?(?:prompt|agent_diff|step_agent_diff)[`"]?/i)).to be_empty
    expect(workflow_payload(response)["runs"].sole).to include("step_kind" => "implement", "agent_summary" => "did it")
  end

  it "caps the runs listed for one workflow and says so" do
    step = Step.create!(workflow: target_workflow, kind: "grader", position: 0)
    (described_class.singleton_class::MAX_RUNS_PER_WORKFLOW + 3).times do
      step.runs.create!(job: target_job, trigger_kind: "initial", state: "failed")
    end

    payload = workflow_payload(call)

    expect(payload["runs"].size).to eq(described_class.singleton_class::MAX_RUNS_PER_WORKFLOW)
    expect(payload["run_count"]).to eq(described_class.singleton_class::MAX_RUNS_PER_WORKFLOW + 3)
    expect(payload["runs_truncated"]).to be(true)
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
