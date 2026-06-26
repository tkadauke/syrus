require "rails_helper"

RSpec.describe "notification event generation" do
  it "creates a job_implemented notification when a job enters implemented" do
    job = Factories.job_record(state: "running", pr_number: 17)

    expect {
      job.notify_job_implemented_on_transition = true
      job.mark_implemented!
      job.save!
    }.to change(Notification, :count).by(1)

    expect(Notification.last).to have_attributes(
      user: job.user,
      kind: "job_implemented",
      job: job,
      pr_url: "https://github.com/#{job.repository.slug}/pull/17",
      body: "Syrus opened PR #17 for JOB-#{job.id}: #{job.title.truncate(80)}"
    )
  end

  it "does not create a job_implemented notification for catch-all implemented transitions" do
    job = Factories.job_record(state: "running", pr_number: 18)

    expect {
      job.mark_implemented!
      job.save!
    }.not_to change(Notification, :count)
  end

  it "creates a job_failed notification when repeated failures close a job" do
    AppSetting.current.update!(max_job_failures: 1)
    job = Factories.job_record(state: "running")

    expect {
      job.record_run_failure!
    }.to change(Notification, :count).by(1)

    expect(Notification.last).to have_attributes(
      user: job.user,
      kind: "job_failed",
      job: job,
      body: "JOB-#{job.id} failed after repeated retries: #{job.title.truncate(80)}"
    )
  end

  it "creates a pr_comment_addressed notification after PR feedback succeeds" do
    job = Factories.job_record(state: "implemented", pr_number: 22)
    workflow = Workflow.create!(
      job: job,
      user: job.user,
      trigger_kind: "pr_comment",
      agent_provider: "codex",
      artifacts: {
        "pr_comments" => [
          { "created_at" => "2026-06-25T04:00:00Z" }
        ]
      }
    )

    expect {
      Workflows::PrFeedback.after_success(workflow)
    }.to change(Notification, :count).by(1)

    expect(Notification.last).to have_attributes(
      user: job.user,
      kind: "pr_comment_addressed",
      job: job,
      pr_url: "https://github.com/#{job.repository.slug}/pull/22",
      body: "Syrus addressed your PR comments on JOB-#{job.id}: #{job.title.truncate(80)}"
    )
  end

  it "creates a pr_merged notification when a job closes as merged" do
    job = Factories.job_record(state: "implemented", pr_number: 23)
    job.update!(closure_reason: "pr_merged")

    expect {
      job.close!
    }.to change(Notification, :count).by(1)

    expect(Notification.last).to have_attributes(
      user: job.user,
      kind: "pr_merged",
      job: job,
      pr_url: "https://github.com/#{job.repository.slug}/pull/23",
      body: "JOB-#{job.id} merged: #{job.title.truncate(80)}"
    )
  end

  it "creates epic_completed notifications for all child job owners" do
    user = Factories.user
    other = Factories.user(notification_preferences: { "epic_completed" => true })
    user.update!(notification_preferences: { "epic_completed" => true })
    repository = Factories.repository(user: user)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress", title: "Ship notifications")
    Factories.job_record(user: user, repository: repository, epic: epic, state: "closed", closure_reason: "pr_merged")
    Factories.job_record(user: user, owner_user: other, repository: repository, epic: epic, state: "closed", closure_reason: "external_pr_merged")
    Notification.delete_all
    epic.update_columns(state: "in_progress", done_at: nil)

    expect {
      epic.reload
      epic.auto_complete!
    }.to change(Notification, :count).by(2)

    expect(Notification.where(kind: "epic_completed").pluck(:user_id, :body)).to contain_exactly(
      [ user.id, "Epic \"Ship notifications\" completed" ],
      [ other.id, "Epic \"Ship notifications\" completed" ]
    )
  end
end
