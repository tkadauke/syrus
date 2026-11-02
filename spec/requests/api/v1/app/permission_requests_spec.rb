require "rails_helper"

RSpec.describe "API: /api/v1/app/permission_requests", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job_record(user:, repository:) }

  before { sign_in_as(user) }

  it "lists the signed-in user's durable requests with redacted decision context" do
    request = authorization_request
    request.authorization_items.create!(item_attributes.merge(
      normalized_arguments: { "api_token" => "secret", "message" => "hello" },
      resource_scope: { "job_id" => job.id }, effects: [ "external_write" ],
      decisive_rule: { "source" => "role_default", "policy" => "ask" }
    ))
    other = Factories.user
    ChatPendingAction.create!(request_kind: "authorization_request", user: other, origin: other, subject: other,
      purpose: "Invisible", deduplication_key: "other")

    get "/api/v1/app/permission_requests"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).fetch("requests")).to contain_exactly(include(
      "id" => request.id, "purpose" => "Publish a status update",
      "origin" => include("type" => "Job", "id" => job.id, "label" => job.slug),
      "items" => [ include(
        "resource_scope" => { "job_id" => job.id }, "effects" => [ "external_write" ],
        "arguments" => { "api_token" => "[redacted]", "message" => "hello" },
        "decisive_rule" => { "source" => "role_default", "policy" => "ask" }
      ) ]
    ))
    expect(response.body).not_to include("secret", "Invisible")
  end

  it "records one compatible decision across the request items" do
    request = authorization_request
    request.authorization_items.create!(item_attributes)

    post "/api/v1/app/permission_requests/#{request.id}/decide", params: { decision: "approved", duration: "job" }

    expect(response).to have_http_status(:ok)
    expect(request.reload).to be_confirmed
    expect(request.authorization_items.first).to have_attributes(
      state: "approved", selected_duration: "job", decision_principal: user
    )
  end

  it "dismisses an obsolete non-actionable request without creating a denial" do
    request = authorization_request
    item = request.authorization_items.create!(item_attributes)
    item.mark_non_actionable!("resource_removed")
    request.mark_non_actionable!("resource_removed")

    delete "/api/v1/app/permission_requests/#{request.id}"

    expect(response).to have_http_status(:ok)
    expect(request.reload).to be_dismissed
    expect(item.reload).to be_non_actionable
  end

  def authorization_request
    ChatPendingAction.create!(request_kind: "authorization_request", user:, repository:, origin: job,
      subject: user, runtime_role: "implementer", purpose: "Publish a status update",
      deduplication_key: "permission-inbox-spec")
  end

  def item_attributes
    {
      kind: "operation", capability: "communication.chat@v1", capability_version: 1,
      operation: "send@v1", operation_version: 1, resource_type: "job",
      resource_scope: {}, normalized_arguments: {}, invocation_fingerprint: "fingerprint",
      effects: [], policy_chain: [], decisive_rule: {}, requested_durations: %w[invocation job]
    }
  end
end
