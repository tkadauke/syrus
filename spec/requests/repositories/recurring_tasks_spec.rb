require "rails_helper"

RSpec.describe "Repository recurring tasks", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  def recurring_task(**overrides)
    RecurringTask.create!({
      user: user,
      repository: repo,
      label: "Daily review",
      prompt: "Review the project.",
      cron_expression: "0 9 * * *"
    }.merge(overrides))
  end

  it "lists recurring tasks for the repository" do
    task = recurring_task

    get repository_recurring_tasks_path(repo)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(task.label)
    expect(response.body).to include(task.cron_expression)
  end

  it "disables and enables a recurring task" do
    task = recurring_task

    patch repository_recurring_task_path(repo, task), params: { enabled: "false" }
    expect(response).to redirect_to(repository_recurring_tasks_path(repo))
    expect(task.reload.enabled).to be(false)

    patch repository_recurring_task_path(repo, task), params: { enabled: "true" }
    expect(task.reload.enabled).to be(true)
  end

  it "deletes a recurring task" do
    task = recurring_task

    expect {
      delete repository_recurring_task_path(repo, task)
    }.to change { RecurringTask.count }.by(-1)
  end
end
