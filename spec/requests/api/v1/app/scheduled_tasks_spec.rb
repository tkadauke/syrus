require "rails_helper"

RSpec.describe "API: /api/v1/app/scheduled_tasks", type: :request do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  let(:valid_cron_attrs) do
    {
      name: "Weekly tests",
      kind: "cron",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip",
      prompt: "Write missing tests."
    }
  end

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/scheduled_tasks"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "lists current user's active, fired, and archived tasks" do
    sign_in_as(user)
    active = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)
    fired = repository.scheduled_tasks.create!(
      user: user,
      **valid_cron_attrs.merge(name: "One shot", kind: "one_shot", cron_expression: nil, fire_at: 1.hour.from_now)
    )
    fired.update!(state: "fired")
    archived = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs.merge(name: "Archived"))
    archived.soft_delete!
    other_repo = Factories.repository(user: other_user)
    other_repo.scheduled_tasks.create!(user: other_user, **valid_cron_attrs.merge(name: "Their task"))

    get "/api/v1/app/scheduled_tasks"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["active_tasks"]).to contain_exactly(include("id" => active.id, "name" => "Weekly tests", "repository" => include("slug" => "acme/widgets")))
    expect(body["fired_one_shots"]).to contain_exactly(include("id" => fired.id, "name" => "One shot"))
    expect(body["archived_tasks"]).to contain_exactly(include("id" => archived.id, "name" => "Archived"))
    expect(body.dig("options", "kinds")).to eq(ScheduledTask::KINDS)
    expect(response.body).not_to include("Their task")
  end

  it "shows a task with recent jobs" do
    sign_in_as(user)
    task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs.merge(auto_approve_mode: "if_graders_pass"))
    job = Factories.job_record(user: user, repository: repository, scheduled_task: task, kind: "cron", issue_number: nil)

    get "/api/v1/app/scheduled_tasks/#{task.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("task", "id")).to eq(task.id)
    expect(body.dig("task", "auto_approve_preview")).to include("repo-committed graders pass")
    expect(body["recent_jobs"]).to contain_exactly(include("id" => job.id, "job_path" => job_path(job)))
  end

  it "returns repository-scoped form defaults from a cron template" do
    sign_in_as(user)
    template = Factories.cron_template(user: user, name: "Template task", prompt: "Keep tidy.")

    get "/api/v1/app/repositories/#{repository.id}/scheduled_tasks/new", params: { from_template: template.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("repository", "slug")).to eq("acme/widgets")
    expect(body.dig("from_template", "id")).to eq(template.id)
    expect(body.dig("task", "name")).to eq("Template task")
    expect(body.dig("task", "prompt")).to eq("Keep tidy.")
    expect(body.dig("task", "cron_template_id")).to eq(template.id)
  end

  it "lists alive scheduled tasks for a repository" do
    sign_in_as(user)
    active = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs.merge(name: "Active"))
    paused = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs.merge(name: "Paused"))
    paused.pause!(reason: "operator")
    archived = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs.merge(name: "Archived"))
    archived.soft_delete!
    other_repo = Factories.repository(user: user, name: "other")
    other_repo.scheduled_tasks.create!(user: user, **valid_cron_attrs.merge(name: "Other repo"))

    get "/api/v1/app/repositories/#{repository.id}/scheduled_tasks"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("repository", "slug")).to eq("acme/widgets")
    expect(body["tasks"]).to contain_exactly(
      include("id" => active.id, "name" => "Active", "active" => true, "prompt" => "Write missing tests."),
      include("id" => paused.id, "name" => "Paused", "active" => false)
    )
    expect(response.body).not_to include("Archived")
    expect(response.body).not_to include("Other repo")
  end

  it "enables and disables repository-scoped tasks" do
    sign_in_as(user)
    task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)

    patch "/api/v1/app/repositories/#{repository.id}/scheduled_tasks/#{task.id}", params: { enabled: "false" }
    expect(response).to have_http_status(:ok)
    expect(task.reload.state).to eq("paused")
    expect(parse_body["message"]).to eq("Scheduled task disabled.")

    patch "/api/v1/app/repositories/#{repository.id}/scheduled_tasks/#{task.id}", params: { enabled: "true" }
    expect(response).to have_http_status(:ok)
    expect(task.reload.state).to eq("scheduled")
    expect(parse_body["message"]).to eq("Scheduled task enabled.")
  end

  it "archives repository-scoped tasks" do
    sign_in_as(user)
    task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)

    delete "/api/v1/app/repositories/#{repository.id}/scheduled_tasks/#{task.id}"

    expect(response).to have_http_status(:ok)
    expect(task.reload.archived?).to be true
    expect(parse_body["message"]).to eq("Scheduled task deleted.")
    expect(parse_body["tasks"]).to be_empty
  end

  it "creates a cron task for a repository" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/scheduled_tasks", params: {
        scheduled_task: valid_cron_attrs.merge(auto_approve_mode: "if_graders_pass")
      }
    }.to change { ScheduledTask.count }.by(1)

    expect(response).to have_http_status(:created)
    task = ScheduledTask.last
    expect(task.user).to eq(user)
    expect(task.repository).to eq(repository)
    expect(task.auto_approve_mode).to eq("if_graders_pass")
    expect(parse_body["message"]).to eq("Scheduled task created.")
  end

  it "returns validation errors for malformed schedules" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/scheduled_tasks", params: {
        scheduled_task: valid_cron_attrs.merge(cron_expression: "not cron")
      }
    }.not_to change { ScheduledTask.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("valid cron expression")
  end

  it "returns validation errors for parser-invalid cron schedules" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/scheduled_tasks", params: {
        scheduled_task: valid_cron_attrs.merge(cron_expression: "49 4 0 0 1")
      }
    }.not_to change { ScheduledTask.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("valid cron expression")
  end

  it "updates a task" do
    sign_in_as(user)
    task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)

    patch "/api/v1/app/scheduled_tasks/#{task.id}", params: {
      scheduled_task: {
        prompt: "Updated standing instruction.",
        auto_approve_mode: "if_graders_pass_and_tagged_safe"
      }
    }

    expect(response).to have_http_status(:ok)
    expect(task.reload.prompt).to eq("Updated standing instruction.")
    expect(task.auto_approve_mode).to eq("if_graders_pass_and_tagged_safe")
    expect(parse_body["message"]).to eq("Scheduled task updated.")
  end

  it "archives a task" do
    sign_in_as(user)
    task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)

    delete "/api/v1/app/scheduled_tasks/#{task.id}"

    expect(response).to have_http_status(:ok)
    expect(task.reload.archived?).to be true
    expect(parse_body["message"]).to eq("Scheduled task archived.")
  end

  it "pauses and resumes a task" do
    sign_in_as(user)
    task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)

    post "/api/v1/app/scheduled_tasks/#{task.id}/pause"
    expect(response).to have_http_status(:ok)
    expect(task.reload.state).to eq("paused")
    expect(parse_body["message"]).to eq("Paused.")

    task.update_columns(consecutive_failure_count: 5)
    post "/api/v1/app/scheduled_tasks/#{task.id}/resume"
    expect(response).to have_http_status(:ok)
    expect(task.reload.state).to eq("scheduled")
    expect(task.consecutive_failure_count).to eq(0)
    expect(parse_body["message"]).to eq("Resumed.")
  end

  it "fires a task immediately through the service boundary" do
    sign_in_as(user)
    task = repository.scheduled_tasks.create!(user: user, **valid_cron_attrs)
    job = Factories.job_record(user: user, repository: repository, scheduled_task: task, kind: "cron", issue_number: nil)
    result = ScheduledTaskFire::Result.new(job: job, skipped: false, reason: nil)
    service = instance_double(ScheduledTaskFire, call: result)
    allow(ScheduledTaskFire).to receive(:new).with(task).and_return(service)

    post "/api/v1/app/scheduled_tasks/#{task.id}/fire_now"

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Fired (job ##{job.id}).")
    expect(parse_body["fire_result"]).to include("fired" => true, "job_id" => job.id)
  end

  it "does not allow managing another user's task" do
    sign_in_as(user)
    other_repo = Factories.repository(user: other_user)
    task = other_repo.scheduled_tasks.create!(user: other_user, **valid_cron_attrs)

    patch "/api/v1/app/scheduled_tasks/#{task.id}", params: {
      scheduled_task: { prompt: "hijack" }
    }

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("not_found")
    expect(task.reload.prompt).to eq("Write missing tests.")
  end
end
