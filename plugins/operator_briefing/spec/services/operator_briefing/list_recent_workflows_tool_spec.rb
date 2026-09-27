require "rails_helper"

RSpec.describe OperatorBriefing::Tools::ListRecentWorkflowsTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_with_run(user: user, repository: repository) }
  let(:workflow) { job.latest_workflow }
  let(:briefing_run) { workflow.steps.first.runs.first }
  let(:window_start) { 2.days.ago.change(usec: 0) }
  let(:window_end) { Time.current.change(usec: 0) }
  let!(:briefing) do
    OperatorBriefing::Briefing.create!(
      job: job,
      repository: repository,
      owner_user: user,
      window_start: window_start,
      window_end: window_end
    )
  end

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    Feature.clear_enabled_cache!("operator_briefing")
  end

  def build_completed_workflow(repository:, finished_at:, user: repository.user,
                               title: "Implement useful change", persisted_kind: nil)
    completed_job = Factories.job_with_run(
      user: user,
      repository: repository,
      issue_title: title,
      workflow_attrs: {
        state: "succeeded",
        started_at: finished_at - 4.minutes,
        finished_at: finished_at
      },
      step_attrs: {
        state: "succeeded",
        started_at: finished_at - 4.minutes,
        finished_at: finished_at - 2.minutes
      },
      run_attrs: {
        state: "succeeded",
        agent_outcome: "success",
        agent_summary: "Run summary",
        started_at: finished_at - 4.minutes,
        finished_at: finished_at - 2.minutes
      }
    )
    completed_job.update_columns(kind: persisted_kind) if persisted_kind.present?
    completed_job.latest_workflow
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "lists completed workflows scoped to the briefing repository, owner, and window" do
    old_workflow = build_completed_workflow(repository: repository, finished_at: window_start - 1.minute)
    recent_workflow = build_completed_workflow(repository: repository, finished_at: window_end - 1.hour, title: "Recent repair")
    foreign_repo_workflow = build_completed_workflow(
      repository: Factories.repository(user: user),
      finished_at: window_end - 30.minutes
    )
    foreign_owner_workflow = build_completed_workflow(
      repository: Factories.repository(user: Factories.user),
      finished_at: window_end - 20.minutes
    )
    infrastructure_workflow = build_completed_workflow(
      repository: repository,
      finished_at: window_end - 10.minutes,
      persisted_kind: "agent_insight"
    )
    unfinished_workflow = build_completed_workflow(repository: repository, finished_at: window_end - 5.minutes)
    unfinished_workflow.update!(state: "running", finished_at: nil)

    response = described_class.call(server_context: { run: briefing_run })

    expect(response).not_to be_error, response.content.first[:text]
    result = payload(response)
    expect(result).to include(
      repository: { id: repository.id, slug: repository.slug },
      window_start: window_start.iso8601,
      window_end: window_end.iso8601,
      total_workflows: 1,
      page: 1,
      per: 20,
      total_pages: 1
    )
    expect(result[:workflows].map { |item| item[:id] }).to eq([ recent_workflow.id ])
    expect(result[:workflows].map { |item| item[:id] }).not_to include(
      old_workflow.id,
      foreign_repo_workflow.id,
      foreign_owner_workflow.id,
      infrastructure_workflow.id,
      unfinished_workflow.id
    )
  end

  it "paginates workflows and serializes summaries, review artifacts, runs, and warnings" do
    newer_workflow = build_completed_workflow(repository: repository, finished_at: window_end - 10.minutes, title: "Newest change")
    older_workflow = build_completed_workflow(repository: repository, finished_at: window_end - 1.hour, title: "Older change")
    run = older_workflow.steps.first.runs.first
    run.update!(agent_summary: "Fallback summary password=hunter2")
    older_workflow.set_artifact!("summary", "Artifact summary CODEX_API_KEY=sk-secret-value-abcdefghijklmnop")
    older_workflow.set_artifact!(
      "adversarial_review_iterations",
      [ { "verdict" => "dismissed", "notes" => "token=ghp_secretvalueabcdefghijklmnop" } ]
    )
    older_workflow.set_artifact!("visual_review_iterations", [ { "verdict" => "clean" } ])
    warning = WorkflowWarnings.record!(
      workflow: older_workflow,
      kind: "review_override",
      severity: "high",
      title: "Finding dismissed password=hunter2",
      evidence: { "note" => "Authorization: Bearer ghp_secretvalueabcdefghijklmnop" }
    )

    response = described_class.call(server_context: { run: briefing_run }, limit: 1, page: 2)

    expect(response).not_to be_error, response.content.first[:text]
    result = payload(response)
    expect(result).to include(total_workflows: 2, page: 2, per: 1, total_pages: 2)
    expect(result[:workflows].map { |item| item[:id] }).to eq([ older_workflow.id ])

    workflow_payload = result[:workflows].first
    expect(workflow_payload[:job]).to include(
      id: older_workflow.job_id,
      kind: "issue",
      title: "Older change",
      path: "/jobs/#{older_workflow.job_id}"
    )
    expect(workflow_payload[:summary]).to match(/\[redacted\]/i)
    expect(workflow_payload[:summary]).not_to include("sk-secret-value-abcdefghijklmnop")
    expect(workflow_payload[:review_artifacts][:adversarial_review_iterations].to_json).to match(/\[redacted\]/i)
    expect(workflow_payload[:review_artifacts][:adversarial_review_iterations].to_json).not_to include("ghp_secretvalue")
    expect(workflow_payload[:review_artifacts][:visual_review_iterations]).to eq([ { verdict: "clean" } ])
    expect(workflow_payload[:step_count]).to eq(1)
    expect(workflow_payload[:run_count]).to eq(1)
    expect(workflow_payload[:runs]).to include(
      include(
        id: run.id,
        state: "succeeded",
        agent_outcome: "success",
        agent_summary: match(/Fallback summary .*?\[redacted\]/i)
      )
    )
    expect(workflow_payload[:warnings]).to include(
      include(
        id: warning.id,
        kind: "review_override",
        severity: "high",
        title: match(/Finding dismissed .*?\[redacted\]/i)
      )
    )
    expect(workflow_payload[:warnings].first[:evidence].to_json).to match(/\[redacted\]/i)
    expect(workflow_payload.to_json).not_to include(
      "hunter2",
      "sk-secret-value-abcdefghijklmnop",
      "ghp_secretvalueabcdefghijklmnop"
    )
    expect(newer_workflow.finished_at).to be > older_workflow.finished_at
  end
end
