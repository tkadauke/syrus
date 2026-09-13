require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/maintenance_tasks", type: :request do
  let(:admin) { Factories.user(admin: true) }

  def parse_body
    JSON.parse(response.body)
  end

  it "paginates task log events 100 entries at a time" do
    sign_in_as(admin)
    task = MaintenanceTask.create!(
      definition_key: "agents_backfill",
      task_key: "spec:agents_backfill",
      state: "running",
      recurrence: "one_off",
      category: "backfill",
      title: "Backfill Agent records",
      summary: "Creates Agent records for historical runs.",
      trigger_kind: "manual",
      trigger_key: "spec",
      required_role: "admin",
      total_units: 105,
      checkpoint: {},
      metadata: {}
    )
    105.times do |index|
      task.events.create!(
        level: "info",
        message: "event #{index + 1}",
        created_at: index.minutes.ago,
        updated_at: index.minutes.ago
      )
    end

    get "/api/v1/app/admin/maintenance_tasks/#{task.id}"

    expect(response).to have_http_status(:ok)
    first_page = parse_body
    expect(first_page.fetch("events").size).to eq(100)
    expect(first_page.fetch("events").first.fetch("message")).to eq("event 1")
    expect(first_page.fetch("events_pagination")).to include(
      "page" => 1,
      "per_page" => 100,
      "total" => 105,
      "total_pages" => 2,
      "first_item" => 1,
      "last_item" => 100,
      "previous_path" => nil,
      "next_path" => "/admin/maintenance_tasks/#{task.id}?page=2"
    )

    get "/api/v1/app/admin/maintenance_tasks/#{task.id}", params: { page: 2 }

    expect(response).to have_http_status(:ok)
    second_page = parse_body
    expect(second_page.fetch("events").size).to eq(5)
    expect(second_page.fetch("events").first.fetch("message")).to eq("event 101")
    expect(second_page.fetch("events_pagination")).to include(
      "page" => 2,
      "first_item" => 101,
      "last_item" => 105,
      "previous_path" => "/admin/maintenance_tasks/#{task.id}",
      "next_path" => nil
    )
  end
end
