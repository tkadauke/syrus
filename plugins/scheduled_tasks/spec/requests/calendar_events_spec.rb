require "rails_helper"

RSpec.describe "Scheduled Tasks Calendar integration", type: :request do
  it "returns an accessible repository schedule through Calendar without duplicates" do
    user = Factories.user
    repository = Factories.repository(user:)
    ScheduledTasks::Task.create!(user:, repository:, name: "Repository sweep", prompt: "Inspect it.",
      kind: "cron", cron_expression: "0 9 * * *", schedule_timezone: "UTC", pr_pileup_policy: "skip")
    sign_in_as(user)
    allow(Calendar).to receive(:enabled?).and_return(true)
    starts_at = 1.day.from_now.beginning_of_day

    get "/api/v1/app/calendar/events", params: { starts_at: starts_at.iso8601, ends_at: (starts_at + 1.day).iso8601 }

    expect(response).to have_http_status(:ok)
    matching = response.parsed_body.fetch("events").select { |event| event["source_id"] == "scheduled_tasks:tasks" }
    expect(matching.one?).to be(true)
    expect(matching.first).to include("title" => "Repository sweep", "state" => "planned",
      "destination_path" => a_string_matching(%r{\A/scheduled_tasks/}))
  end
end
