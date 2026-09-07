require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/attention_items", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/attention_items"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/attention_items"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "lists open attention items" do
    sign_in_as(admin)
    repo = Factories.repository
    item = Factories.attention_item(repository: repo, title: "rspec failure")

    get "/api/v1/app/admin/attention_items"

    expect(response).to have_http_status(:ok)
    expect(parse_body["items"].map { |row| row["id"] }).to eq([ item.id ])
    expect(parse_body["items"].first["title"]).to eq("rspec failure")
  end

  it "records a decision and excludes it from the default open view afterward" do
    sign_in_as(admin)
    item = Factories.attention_item(repository: Factories.repository)

    post "/api/v1/app/admin/attention_items/#{item.id}/decide", params: { resolution: "dismissed", reason: "known upstream issue" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["state"]).to eq("decided")
    expect(parse_body["resolution"]).to eq("dismissed")
    expect(item.reload.decided_by_user).to eq(admin)

    get "/api/v1/app/admin/attention_items"
    expect(parse_body["items"]).to be_empty
  end

  it "rejects an unknown resolution" do
    sign_in_as(admin)
    item = Factories.attention_item(repository: Factories.repository)

    post "/api/v1/app/admin/attention_items/#{item.id}/decide", params: { resolution: "ignored" }

    expect(response).to have_http_status(:bad_request)
    expect(item.reload).to be_open
  end

  it "runs a typed action and returns the refreshed item" do
    sign_in_as(admin)
    job = Factories.job_record
    Workflows::Initial.instantiate(job: job).update!(state: "succeeded")
    item = Factories.attention_item(
      repository: job.repository,
      job: job,
      actions: [ { "action_key" => "retry_job", "label" => "Retry", "payload" => { "job_id" => job.id } } ]
    )

    expect {
      post "/api/v1/app/admin/attention_items/#{item.id}/act", params: { action_key: "retry_job" }
    }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(parse_body["id"]).to eq(item.id)

    audit = AdminAction.last
    expect(audit.action).to eq("attention_item_retry_job")
    expect(audit.user).to eq(admin)
  end

  it "422s when the action isn't one of the item's own actions" do
    sign_in_as(admin)
    item = Factories.attention_item(
      repository: Factories.repository,
      actions: [ { "action_key" => "cancel_job", "label" => "Not actionable", "payload" => { "job_id" => 0 } } ]
    )

    post "/api/v1/app/admin/attention_items/#{item.id}/act", params: { action_key: "retry_job" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(parse_body.dig("error", "code")).to eq("action_failed")
  end
end
