require "rails_helper"

# Covers the per-repo ScheduledTasks tab (Repositories::ScheduledTasksController).
# Full operator CRUD lives at /scheduled_tasks (top-level); this controller
# only handles the lightweight per-repo list + enable/disable/delete the
# chat agent's `schedule_recurring` MCP tool produces.
RSpec.describe "Repository scheduled tasks", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  def scheduled_task(**overrides)
    ScheduledTask.create!({
      user: user,
      repository: repo,
      kind: "cron",
      name: "Daily review",
      prompt: "Review the project.",
      cron_expression: "0 9 * * *"
    }.merge(overrides))
  end

  it "lists scheduled tasks for the repository" do
    task = scheduled_task

    get repository_scheduled_tasks_path(repo)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(task.name)
    expect(response.body).to include(task.hourly_cron_expression)
  end

  it "disables and enables a scheduled task via state transitions" do
    task = scheduled_task

    patch repository_scheduled_task_path(repo, task), params: { enabled: "false" }
    expect(response).to redirect_to(repository_scheduled_tasks_path(repo))
    expect(task.reload.state).to eq("paused")

    patch repository_scheduled_task_path(repo, task), params: { enabled: "true" }
    expect(task.reload.state).to eq("scheduled")
  end

  it "soft-deletes a scheduled task" do
    task = scheduled_task

    expect {
      delete repository_scheduled_task_path(repo, task)
    }.to change { ScheduledTask.alive.count }.by(-1)

    expect(task.reload.archived_at).to be_present
  end
end
