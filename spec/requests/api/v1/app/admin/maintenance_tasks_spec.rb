require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/maintenance_tasks", type: :request do
  def parse_body = JSON.parse(response.body)

  def maintenance_task(**attrs)
    MaintenanceTask.create!({
      definition_key: "agents_backfill",
      task_key: "spec:agents_backfill:#{SecureRandom.hex(4)}",
      state: "running",
      recurrence: "one_off",
      category: "backfill",
      title: "Backfill Agent records",
      summary: "Creates Agent records for historical work.",
      trigger_kind: "manual",
      trigger_key: "spec",
      required_role: "admin",
      checkpoint: {},
      metadata: {}
    }.merge(attrs))
  end

  it "returns maintenance task log entries paginated at 100 per page" do
    admin = Factories.user
    task = maintenance_task
    105.times do |index|
      task.events.create!(
        level: "info",
        message: "event #{index + 1}",
        created_at: index.seconds.ago,
        updated_at: index.seconds.ago
      )
    end
    sign_in_as(admin)

    get "/api/v1/app/admin/maintenance_tasks/#{task.id}", params: { log_page: 2 }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.fetch("events").size).to eq(5)
    expect(body.fetch("events").map { |event| event.fetch("message") }).to eq(
      [ "event 101", "event 102", "event 103", "event 104", "event 105" ]
    )
    expect(body.fetch("events_pagination")).to include(
      "page" => 2,
      "per_page" => 100,
      "total_events" => 105,
      "total_pages" => 2,
      "first_item" => 101,
      "last_item" => 105,
      "previous_page" => 1,
      "next_page" => nil,
      "has_previous_page" => true,
      "has_next_page" => false
    )
  end

  it "returns the index with shared table pagination and sorting metadata" do
    admin = Factories.user
    old_task = maintenance_task(title: "Old task", updated_at: 2.days.ago)
    new_task = maintenance_task(title: "New task", updated_at: 1.day.ago)
    sign_in_as(admin)

    get "/api/v1/app/admin/maintenance_tasks", params: { per_page: 1, sort: "title", direction: "desc" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.fetch("tasks").map { |task| task.fetch("id") }).to eq([ old_task.id ])
    expect(body.fetch("total")).to eq(2)
    expect(body.fetch("pagination")).to include(
      "page" => 1,
      "per_page" => 1,
      "total" => 2,
      "total_pages" => 2,
      "first_item" => 1,
      "last_item" => 1,
      "next_page" => 2
    )
    expect(body.fetch("sort")).to eq("column" => "title", "direction" => "desc")
    expect(new_task).to be_present
  end
end
