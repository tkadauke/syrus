require "rails_helper"

RSpec.describe "API: /api/v1/app/notifications", type: :request do
  let(:user) { Factories.user }
  let(:other) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  def notification_for(target_user, **attrs)
    Notification.create!({
      user: target_user,
      kind: "job_failed",
      body: "Build failed"
    }.merge(attrs))
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/notifications"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "lists paginated notifications for the current user newest first with unread count" do
    sign_in_as(user)
    job = Factories.job_record(user: user)
    old = notification_for(
      user,
      kind: "pr_merged",
      body: "Merged",
      job: job,
      pr_url: "https://github.com/acme/widgets/pull/7",
      read_at: 1.hour.ago,
      created_at: 2.days.ago
    )
    fresh = notification_for(user, kind: "job_implemented", body: "Opened PR", created_at: 1.hour.ago)
    notification_for(other, body: "Not yours", created_at: Time.current)

    get "/api/v1/app/notifications"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["unread_count"]).to eq(1)
    expect(body["notifications"].map { |notification| notification["id"] }).to eq([ fresh.id, old.id ])
    expect(body["notifications"].first).to include(
      "id" => fresh.id,
      "kind" => "job_implemented",
      "body" => "Opened PR",
      "read_at" => nil,
      "pr_url" => nil,
      "job_id" => nil
    )
    expect(body["notifications"].first["created_at"]).to be_present
    expect(body["notifications"].second).to include(
      "id" => old.id,
      "kind" => "pr_merged",
      "body" => "Merged",
      "pr_url" => "https://github.com/acme/widgets/pull/7",
      "job_id" => job.id
    )
    expect(body["notifications"].second["read_at"]).to be_present
    expect(body["pagination"]).to include("page" => 1, "per_page" => 20, "total" => 2, "total_pages" => 1)
    expect(response.body).not_to include("Not yours")
  end

  it "filters unread notifications" do
    sign_in_as(user)
    read = notification_for(user, body: "Read", read_at: Time.current)
    unread = notification_for(user, body: "Unread")

    get "/api/v1/app/notifications", params: { unread: "true" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["notifications"].map { |notification| notification["id"] }).to eq([ unread.id ])
    expect(parse_body["unread_count"]).to eq(1)
    expect(parse_body["notifications"].map { |notification| notification["id"] }).not_to include(read.id)
  end

  it "marks all current-user notifications read" do
    sign_in_as(user)
    unread = notification_for(user)
    already_read = notification_for(user, read_at: 1.day.ago)
    foreign = notification_for(other)

    post "/api/v1/app/notifications/mark_all_read"

    expect(response).to have_http_status(:ok)
    expect(unread.reload.read_at).to be_present
    expect(already_read.reload.read_at).to be_present
    expect(foreign.reload.read_at).to be_nil
    expect(parse_body["unread_count"]).to eq(0)
  end

  it "marks one notification read idempotently" do
    sign_in_as(user)
    notification = notification_for(user)

    patch "/api/v1/app/notifications/#{notification.id}/mark_read"

    expect(response).to have_http_status(:ok)
    first_read_at = notification.reload.read_at
    expect(first_read_at).to be_present
    expect(parse_body["notification"]).to include("id" => notification.id)
    expect(parse_body["unread_count"]).to eq(0)

    travel 5.minutes do
      patch "/api/v1/app/notifications/#{notification.id}/mark_read"
    end

    expect(response).to have_http_status(:ok)
    expect(notification.reload.read_at.to_i).to eq(first_read_at.to_i)
    expect(parse_body["unread_count"]).to eq(0)
  end

  it "does not allow marking another user's notification read" do
    sign_in_as(user)
    notification = notification_for(other)

    patch "/api/v1/app/notifications/#{notification.id}/mark_read"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("not_found")
    expect(notification.reload.read_at).to be_nil
  end
end

RSpec.describe "API: /api/v1/app/notification_preferences", type: :request do
  let(:user) { Factories.user(notification_preferences: { "job_failed" => false }) }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/notification_preferences"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "returns stored preferences merged with defaults" do
    sign_in_as(user)

    get "/api/v1/app/notification_preferences"

    expect(response).to have_http_status(:ok)
    expect(parse_body["notification_preferences"]).to eq(
      User::NOTIFICATION_PREFERENCES_DEFAULTS.merge("job_failed" => false)
    )
  end

  it "updates a partial preference hash without replacing existing preferences" do
    sign_in_as(user)

    patch "/api/v1/app/notification_preferences", params: {
      notification_preferences: {
        "job_implemented" => false,
        "epic_completed" => true
      }
    }

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Notification preferences updated.")
    expect(parse_body["notification_preferences"]).to include(
      "job_failed" => false,
      "job_implemented" => false,
      "epic_completed" => true
    )
    expect(user.reload.notification_preference_for("pr_merged")).to be(true)
  end
end
