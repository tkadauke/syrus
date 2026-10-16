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

  it "includes checkpointed unresolved landing details on the task detail payload" do
    admin = Factories.user
    task = maintenance_task(
      definition_key: "landed_commits_backfill",
      task_key: "spec:landed-commits",
      title: "Backfill landed commit records",
      summary: "Records historical landed commits.",
      checkpoint: {
        "unresolved_repositories" => [
          {
            "id" => 42,
            "slug" => "acme/widgets",
            "errors" => 1,
            "failure_details" => [
              {
                "repository_slug" => "acme/widgets",
                "landable_type" => "Job",
                "landable_id" => 123,
                "landable_slug" => "JOB-123",
                "exception_class" => "ArgumentError",
                "message" => "expected 1 commit"
              }
            ],
            "failure_details_omitted" => 0
          }
        ]
      }
    )
    sign_in_as(admin)

    get "/api/v1/app/admin/maintenance_tasks/#{task.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("checkpoint", "unresolved_repositories")).to contain_exactly(
      hash_including(
        "slug" => "acme/widgets",
        "errors" => 1,
        "failure_details" => [
          hash_including(
            "landable_slug" => "JOB-123",
            "exception_class" => "ArgumentError",
            "message" => "expected 1 commit"
          )
        ]
      )
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

  it "returns a conflict when a stale start action is no longer runnable" do
    admin = Factories.user
    task = maintenance_task(state: "succeeded")
    sign_in_as(admin)

    post "/api/v1/app/admin/maintenance_tasks/#{task.id}/start"

    expect(response).to have_http_status(:conflict)
    expect(parse_body.dig("error", "code")).to eq("maintenance_task_conflict")
    expect(parse_body.dig("error", "message")).to eq("maintenance task is not runnable from succeeded")
  end

  it "does not append another event when an already-dismissed task is dismissed again" do
    admin = Factories.user
    task = maintenance_task(state: "dismissed", dismissed_at: 1.hour.ago, dismissed_by_user: admin)
    task.events.create!(level: "info", message: "Dismissed previously.")
    dismissed_at = task.dismissed_at
    sign_in_as(admin)

    post "/api/v1/app/admin/maintenance_tasks/#{task.id}/dismiss"

    expect(response).to have_http_status(:ok)
    expect(task.reload.dismissed_at).to eq(dismissed_at)
    expect(task.events.pluck(:message)).to eq([ "Dismissed previously." ])
  end

  it "does not disguise unrelated discovery argument errors as action conflicts" do
    admin = Factories.user
    sign_in_as(admin)
    allow(MaintenanceTasks::Discovery).to receive(:call).and_raise(ArgumentError, "invalid discovery definition")

    expect {
      post "/api/v1/app/admin/maintenance_tasks/discover"
    }.to raise_error(ArgumentError, "invalid discovery definition")
  end
end
