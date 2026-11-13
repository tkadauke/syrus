require "rails_helper"

RSpec.describe "API: /api/v1/app/maintenance_tasks/sidebar", type: :request do
  def parse_body = JSON.parse(response.body)

  it "does not expose or calculate maintenance tasks for non-admins" do
    Factories.user(admin: true)
    sign_in_as(Factories.user(global_role: "user"))

    expect(App::MaintenanceTasksPayload).not_to receive(:sidebar)
    get "/api/v1/app/maintenance_tasks/sidebar"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("v" => 1, "tasks" => [])
  end

  it "returns a slim conditional payload for admins" do
    task = MaintenanceTask.create!(
      definition_key: "agents_backfill",
      task_key: "spec:sidebar",
      state: "running",
      recurrence: "one_off",
      category: "backfill",
      title: "Backfill agents",
      summary: "A deliberately omitted summary",
      trigger_kind: "manual",
      trigger_key: "spec",
      required_role: "admin",
      checkpoint: {},
      metadata: { "rebuild_plan" => [ "omitted" ] }
    )
    sign_in_as(Factories.user(admin: true))

    get "/api/v1/app/maintenance_tasks/sidebar"

    expect(response).to have_http_status(:ok)
    payload = parse_body.fetch("tasks").sole
    expect(payload).to include("id" => task.id, "title" => "Backfill agents", "paths" => { "admin" => "/admin/maintenance_tasks/#{task.id}" })
    expect(payload).not_to include("summary", "steps", "rebuild_plan", "last_error", "requested_by")

    get "/api/v1/app/maintenance_tasks/sidebar", headers: { "If-None-Match" => response.headers.fetch("ETag") }
    expect(response).to have_http_status(:not_modified)
  end
end
