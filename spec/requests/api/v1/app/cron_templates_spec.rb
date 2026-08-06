require "rails_helper"

RSpec.describe "API: /api/v1/app/cron_templates", type: :request do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }

  let(:valid_attrs) do
    {
      name: "Weekly dependency bump",
      description: "Keep dependencies moving.",
      prompt: "Bump outdated gems.",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip",
      enabled: true
    }
  end

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/cron_templates"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "previews cron input as a canonical RRULE schedule" do
    sign_in_as(user)

    post "/api/v1/app/cron_templates/preview_schedule", params: { schedule_input: "0 9 14 8 *" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "valid" => true,
      "schedule_expression" => "FREQ=YEARLY;BYMONTH=8;BYMONTHDAY=14;BYHOUR=9;BYMINUTE=0;BYSECOND=0",
      "schedule_explanation" => "Every August 14 at 9:00 AM UTC"
    )
  end

  it "lists only the current user's cron templates" do
    sign_in_as(user)
    template = user.cron_templates.create!(valid_attrs)
    other_user.cron_templates.create!(valid_attrs.merge(name: "Their template"))

    get "/api/v1/app/cron_templates"

    expect(response).to have_http_status(:ok)
    expect(parse_body["templates"]).to contain_exactly(
      include(
        "id" => template.id,
        "name" => "Weekly dependency bump",
        "cron_expression" => "0 9 * * 1",
        "pr_pileup_policy" => "skip",
        "enabled" => true,
        "applied_tasks_count" => 0
      )
    )
    expect(parse_body["pr_pileup_policies"]).to eq(CronTemplate::PR_PILEUP_POLICIES)
    expect(response.body).not_to include("Their template")
  end

  it "shows a template with active repositories and applied tasks" do
    sign_in_as(user)
    template = user.cron_templates.create!(valid_attrs)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    archived_repository = Factories.repository(user: user, owner: "acme", name: "archived", archived_at: Time.current)
    task = ScheduledTask.create!(
      user: user,
      repository: repository,
      cron_template: template,
      kind: "cron",
      name: "Weekly task",
      prompt: "Do it.",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip",
      last_fired_at: Time.utc(2026, 5, 30, 12)
    )

    get "/api/v1/app/cron_templates/#{template.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("template", "prompt")).to eq("Bump outdated gems.")
    expect(body["repositories"]).to contain_exactly(
      include(
        "id" => repository.id,
        "slug" => "acme/widgets",
        "new_scheduled_task_path" => new_repository_scheduled_task_path(repository, from_template: template.id)
      )
    )
    expect(body["repositories"].map { |row| row["id"] }).not_to include(archived_repository.id)
    expect(body["applied_tasks"]).to contain_exactly(
      include(
        "id" => task.id,
        "name" => "Weekly task",
        "state" => "scheduled",
        "repository_slug" => "acme/widgets",
        "last_fired_at" => "2026-05-30T12:00:00Z",
        "scheduled_task_path" => scheduled_task_path(task),
        "repository_path" => repository_path(repository)
      )
    )
  end

  it "creates a template" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/cron_templates", params: { cron_template: valid_attrs }
    }.to change { user.cron_templates.count }.by(1)

    expect(response).to have_http_status(:created)
    template = user.cron_templates.last
    expect(template.name).to eq("Weekly dependency bump")
    expect(parse_body["message"]).to eq("Template created.")
    expect(parse_body.dig("template", "id")).to eq(template.id)
  end

  it "returns validation errors" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/cron_templates",
           params: { cron_template: valid_attrs.merge(cron_expression: "not cron") }
    }.not_to change { user.cron_templates.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("five-field cron expression")
  end

  it "updates a template" do
    sign_in_as(user)
    template = user.cron_templates.create!(valid_attrs)

    patch "/api/v1/app/cron_templates/#{template.id}", params: {
      cron_template: { prompt: "Updated prompt.", enabled: false }
    }

    expect(response).to have_http_status(:ok)
    expect(template.reload.prompt).to eq("Updated prompt.")
    expect(template.enabled).to be(false)
    expect(parse_body["message"]).to eq("Template updated.")
  end

  it "deletes a template" do
    sign_in_as(user)
    template = user.cron_templates.create!(valid_attrs)

    expect {
      delete "/api/v1/app/cron_templates/#{template.id}"
    }.to change { user.cron_templates.count }.by(-1)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Template deleted.")
    expect(parse_body["templates"]).to eq([])
  end

  it "does not allow managing another user's template" do
    sign_in_as(user)
    template = other_user.cron_templates.create!(valid_attrs)

    patch "/api/v1/app/cron_templates/#{template.id}", params: {
      cron_template: { prompt: "hijack" }
    }

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("not_found")
    expect(template.reload.prompt).to eq("Bump outdated gems.")
  end
end
