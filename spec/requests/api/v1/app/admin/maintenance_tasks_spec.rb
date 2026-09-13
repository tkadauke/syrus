require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/maintenance_tasks", type: :request do
  def parse_body = JSON.parse(response.body)

  it "paginates task log events 100 at a time" do
    admin = Factories.user(admin: true)
    sign_in_as(admin)
    task = MaintenanceTask.create!(
      definition_key: "agents_backfill",
      task_key: "spec:agents_backfill:#{SecureRandom.hex(4)}",
      state: "running",
      recurrence: "one_off",
      category: "backfill",
      title: "Backfill Agent records",
      summary: "Creates missing Agent records.",
      trigger_kind: "manual",
      trigger_key: "spec",
      required_role: "admin",
      checkpoint: {},
      metadata: {}
    )
    base_time = Time.zone.parse("2026-09-13 12:00:00")
    105.times do |index|
      task.events.create!(
        level: "info",
        message: "event #{index + 1}",
        created_at: base_time + index.seconds,
        updated_at: base_time + index.seconds
      )
    end

    get "/api/v1/app/admin/maintenance_tasks/#{task.id}", params: { events_page: 2 }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["events"].size).to eq(5)
    expect(body["events"].map { |event| event["message"] }).to eq([ "event 5", "event 4", "event 3", "event 2", "event 1" ])
    expect(body["events_pagination"]).to include(
      "page" => 2,
      "per_page" => 100,
      "total" => 105,
      "total_pages" => 2,
      "first_item" => 101,
      "last_item" => 105,
      "previous_path" => "/admin/maintenance_tasks/#{task.id}?events_page=1",
      "next_path" => nil
    )
  end
end
