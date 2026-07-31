require "rails_helper"

RSpec.describe ChatPendingActionOutcomeNotification do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, last_message_at: Time.current) }

  def build_action(attrs)
    chat_session.pending_actions.build(attrs)
  end

  it "builds a confirmed message for a job-scoped action" do
    action = build_action(action: "cancel_job", payload: { "job_id" => 42 })

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to eq(
      "Pending action confirmed: cancel_job (job_id: 42). The action has been applied."
    )
  end

  it "builds a confirmed message with partial GitHub cleanup details" do
    action = build_action(
      action: "close_job_successfully",
      payload: {
        "job_id" => 42,
        "closure_reason" => "no_changes",
        "github_result" => {
          "status" => "partial_failure",
          "pr_number" => 7,
          "comment" => { "status" => "failed", "error" => "Octokit::Forbidden: nope" },
          "close" => { "status" => "closed" }
        }
      }
    )

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to eq(
      "Pending action confirmed: close_job_successfully (job_id: 42, closure_reason: no_changes). The action has been applied. Job state was closed successfully, but PR cleanup was partial: Octokit::Forbidden: nope."
    )
  end

  it "builds a rejected message for a job-scoped action" do
    action = build_action(action: "retry_job", payload: { "job_id" => 7 })

    expect(described_class.new(action).acknowledgment(outcome: :rejected)).to eq(
      "Pending action rejected: retry_job (job_id: 7). The action was not applied."
    )
  end

  it "builds a cancelled message for a job-scoped action" do
    action = build_action(action: "rebase_job", payload: { "job_id" => 5 })

    expect(described_class.new(action).acknowledgment(outcome: :cancelled)).to eq(
      "Pending action dismissed: rebase_job (job_id: 5). The action was not applied."
    )
  end

  it "includes both epic_id and job_id for reopen_epic_and_attach_job" do
    action = build_action(action: "reopen_epic_and_attach_job", payload: { "epic_id" => 10, "job_id" => 20 })

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to eq(
      "Pending action confirmed: reopen_epic_and_attach_job (epic_id: 10, job_id: 20). The action has been applied."
    )
  end

  it "includes scheduled_task_id for fire_scheduled_task_now" do
    action = build_action(action: "fire_scheduled_task_now", payload: { "scheduled_task_id" => 3 })

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to include("scheduled_task_id: 3")
  end

  it "includes title for create_repo_document" do
    action = build_action(action: "create_repo_document", payload: { "repository_id" => 1, "title" => "API Guide", "body" => "..." })

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to include("title: API Guide")
  end

  it "includes document_id for delete_repo_document" do
    action = build_action(action: "delete_repo_document", payload: { "document_id" => 99 })

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to include("document_id: 99")
  end

  it "includes issue_number for delegate_issue" do
    action = build_action(action: "delegate_issue", payload: { "repository_id" => 1, "issue_number" => 123 })

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to include("issue_number: 123")
  end

  it "includes process_id for admin_kill_process" do
    action = build_action(action: "admin_kill_process", payload: { "process_id" => 55 }, requested_by: "agent")

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to include("process_id: 55")
  end

  it "includes user_id for admin_pause_user_scheduling" do
    action = build_action(action: "admin_pause_user_scheduling", payload: { "user_id" => 8 }, requested_by: "agent")

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to include("user_id: 8")
  end

  it "includes workflow_id and step_slug for admin_retry_step" do
    action = build_action(action: "admin_retry_step", payload: { "workflow_id" => 100, "step_slug" => "implement" }, requested_by: "agent")

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to include("workflow_id: 100, step_slug: implement")
  end

  it "includes workflow_id for admin_cleanup_workspace" do
    action = build_action(action: "admin_cleanup_workspace", payload: { "workflow_id" => 200 }, requested_by: "agent")

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to include("workflow_id: 200")
  end

  it "includes label for schedule_recurring action_type" do
    action = chat_session.pending_actions.build(
      action_type: "schedule_recurring",
      payload: { "cron_expression" => "0 9 * * *", "label" => "Daily scan", "prompt" => "Scan it." }
    )

    expect(described_class.new(action).acknowledgment(outcome: :confirmed)).to include("label: Daily scan")
  end

  it "includes no ID for empty-payload actions" do
    action = build_action(action: "pause_landing_queue", payload: {})

    text = described_class.new(action).acknowledgment(outcome: :confirmed)
    expect(text).to include("pause_landing_queue")
    expect(text).to include("The action has been applied.")
  end

  it "raises on unknown outcome" do
    action = build_action(action: "pause_landing_queue", payload: {})

    expect { described_class.new(action).acknowledgment(outcome: :unknown) }.to raise_error(ArgumentError)
  end
end
