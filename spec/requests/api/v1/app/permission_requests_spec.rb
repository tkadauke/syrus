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
    payload = JSON.parse(response.body)
    expect(payload.fetch("pagination")).to include("page" => 1, "per_page" => 50, "total" => 1)
    expect(payload.fetch("summary")).to eq("pending_count" => 1, "blocked_agent_count" => 0)
    expect(payload.fetch("requests")).to contain_exactly(include(
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


  it "summarizes pending requests and agents blocked at authorization checkpoints" do
    waiting = authorization_request
    waiting.update!(checkpoint_state: "waiting", checkpointed_at: Time.current)
    authorization_request(deduplication_key: "permission-inbox-spec-2")
    completed = authorization_request(deduplication_key: "permission-inbox-spec-3")
    completed.update!(state: "confirmed")

    get "/api/v1/app/permission_requests"

    expect(JSON.parse(response.body).fetch("summary")).to eq("pending_count" => 2, "blocked_agent_count" => 1)
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

  it "denies every pending item without requiring a duration" do
    request = authorization_request
    request.authorization_items.create!(item_attributes.merge(requested_durations: [ "job" ]))

    post "/api/v1/app/permission_requests/#{request.id}/decide", params: { decision: "denied" }

    expect(response).to have_http_status(:ok)
    expect(request.reload).to be_rejected
    expect(request.authorization_items.first).to have_attributes(state: "denied", selected_duration: nil)
  end

  it "rejects a duration that is not compatible with every item without partially deciding" do
    request = authorization_request
    request.authorization_items.create!(item_attributes.merge(invocation_fingerprint: "first"))
    request.authorization_items.create!(item_attributes.merge(invocation_fingerprint: "second", requested_durations: [ "invocation" ]))

    post "/api/v1/app/permission_requests/#{request.id}/decide", params: { decision: "approved", duration: "job" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(request.reload).to be_pending
    expect(request.authorization_items.reload).to all(be_pending)
  end

  it "does not replay a decision over a terminal request" do
    request = authorization_request
    request.authorization_items.create!(item_attributes)
    post "/api/v1/app/permission_requests/#{request.id}/decide", params: { decision: "denied" }

    post "/api/v1/app/permission_requests/#{request.id}/decide", params: { decision: "approved", duration: "job" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(request.reload).to be_rejected
    expect(request.authorization_items.first.reload).to be_denied
  end

  it "only lets a coworker permission request be denied through the generic decision endpoints" do
    coworker = Coworkers::Coworker.create!(owner_user: user, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
    request = ChatPendingAction.create!(request_kind: "authorization_request", user:, repository:, origin: job,
      subject: coworker, runtime_role: AgentRole::COWORKER_CHAT, purpose: "Read orders",
      action: "coworker_permission_request", requested_by: "agent", deduplication_key: "coworker-permission-request-spec",
      payload: { "requested_duration" => "chat_session" })
    request.authorization_items.create!(item_attributes.merge(requested_durations: %w[chat_session]))

    post "/api/v1/app/permission_requests/#{request.id}/decide", params: { decision: "approved", duration: "chat_session" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(request.reload).to be_pending

    post "/api/v1/app/permission_requests/batch_decide", params: { request_ids: [ request.id ], decision: "denied" }

    expect(response).to have_http_status(:ok)
    expect(request.reload).to be_rejected
    expect(request.rejected_at).to be_present
    expect(AdminAction.where(action: "coworker_permission_request_denied").count).to eq(1)
  end

  it "denies a batch of coworker permission requests atomically" do
    coworker = Coworkers::Coworker.create!(owner_user: user, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
    build = lambda do |key|
      ChatPendingAction.create!(request_kind: "authorization_request", user:, repository:, origin: job,
        subject: coworker, runtime_role: AgentRole::COWORKER_CHAT, purpose: "Read orders",
        action: "coworker_permission_request", requested_by: "agent", deduplication_key: key,
        payload: { "requested_duration" => "chat_session" }).tap do |request|
        request.authorization_items.create!(item_attributes.merge(requested_durations: %w[chat_session]))
      end
    end
    fresh = build.call("batch-fresh")
    stale = build.call("batch-stale")
    stale.update!(state: "cancelled")

    post "/api/v1/app/permission_requests/batch_decide", params: { request_ids: [ fresh.id, stale.id ], decision: "denied" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(fresh.reload).to be_pending
    expect(fresh.authorization_items.first).to be_pending
    expect(AdminAction.where(action: "coworker_permission_request_denied")).to be_empty
  end

  it "decides a compatible batch atomically" do
    first = authorization_request
    second = authorization_request(deduplication_key: "permission-inbox-spec-2")
    first.authorization_items.create!(item_attributes.merge(invocation_fingerprint: "first"))
    second.authorization_items.create!(item_attributes.merge(invocation_fingerprint: "second"))

    post "/api/v1/app/permission_requests/batch_decide", params: { request_ids: [ first.id, second.id ], decision: "approved", duration: "job" }

    expect(response).to have_http_status(:ok)
    expect([ first.reload.state, second.reload.state ]).to eq(%w[confirmed confirmed])
  end

  it "rejects a mixed-compatibility batch without deciding any request" do
    first = authorization_request
    second = authorization_request(deduplication_key: "permission-inbox-spec-2")
    first.authorization_items.create!(item_attributes.merge(invocation_fingerprint: "first"))
    second.authorization_items.create!(item_attributes.merge(invocation_fingerprint: "second", requested_durations: [ "invocation" ]))

    post "/api/v1/app/permission_requests/batch_decide", params: { request_ids: [ first.id, second.id ], decision: "approved", duration: "job" }

    expect(response).to have_http_status(:unprocessable_content)
    expect([ first.reload.state, second.reload.state ]).to eq(%w[pending pending])
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

  it "refuses to dismiss a completed request" do
    request = authorization_request
    request.update!(state: "confirmed")

    delete "/api/v1/app/permission_requests/#{request.id}"

    expect(response).to have_http_status(:unprocessable_content)
    expect(request.reload).to be_confirmed
  end

  describe "server-side filters" do
    def q(*chips) = Filters::QueryParam.encode({ "and" => chips.map { |field, value| { "field" => field, "op" => "is_one_of", "value" => value } } })

    def add_request(key, operation:, effects:, state: "pending", origin: job)
      request = authorization_request(deduplication_key: key)
      request.update!(state:, origin:)
      request.authorization_items.create!(item_attributes.merge(operation:, effects:, invocation_fingerprint: key))
      request
    end

    it "filters before counting and pagination, combining filters with AND" do
      stub_const("Api::V1::App::PermissionRequestsController::PER_PAGE", 2)
      60.times { |i| add_request("noise-#{i}", operation: "send@v1", effects: [ "communication" ]) }
      target = add_request("needle", operation: "delete@v1", effects: [ "destructive" ], state: "confirmed")

      get "/api/v1/app/permission_requests", params: { q: q([ "effect", [ "destructive" ] ]) }
      body = JSON.parse(response.body)
      expect(body.fetch("requests").map { |r| r["id"] }).to eq([ target.id ])
      expect(body.fetch("pagination")).to include("total" => 1, "total_pages" => 1)

      get "/api/v1/app/permission_requests", params: { q: q([ "action", [ "delete@v1" ] ], [ "state", [ "pending" ] ]) }
      expect(JSON.parse(response.body).fetch("requests")).to be_empty

      get "/api/v1/app/permission_requests", params: { q: q([ "action", [ "delete@v1" ] ], [ "state", [ "confirmed" ] ], [ "origin_type", [ "Job" ] ],
        [ "subject", [ "User:#{user.id}" ] ]) }
      expect(JSON.parse(response.body).fetch("requests").map { |r| r["id"] }).to eq([ target.id ])

      get "/api/v1/app/permission_requests", params: { q: q([ "state", [ "pending" ] ]), page: 2 }
      body = JSON.parse(response.body)
      expect(body.fetch("pagination")).to include("page" => 2, "total" => 60, "total_pages" => 30)
      expect(body.fetch("requests").length).to eq(2)
    end

    it "returns labeled, visibility-safe options for the whole scope and humanized presentation" do
      add_request("one", operation: "send@v1", effects: [ "communication" ])
      other = Factories.user
      ChatPendingAction.create!(request_kind: "authorization_request", user: other, origin: other, subject: other, purpose: "Invisible", deduplication_key: "other-user")
        .authorization_items.create!(item_attributes.merge(operation: "hidden@v1", effects: [ "financial" ]))

      get "/api/v1/app/permission_requests", params: { q: q([ "state", [ "confirmed" ] ]) }
      body = JSON.parse(response.body)
      expect(body.fetch("requests")).to be_empty
      options = body.fetch("filter_options")
      expect(options.fetch("effect")).to eq([ { "value" => "communication", "label" => "send a message" } ])
      expect(options.fetch("action").map { |o| o["value"] }).to eq([ "send@v1" ])
      expect(options.fetch("origin_type")).to eq([ { "value" => "Job", "label" => "Job" } ])
      expect(options.fetch("subject").map { |o| o["value"] }).to eq([ "User:#{user.id}" ])
      expect(options.fetch("state").map { |o| o["label"] }).to include("Pending", "Approved", "Denied")
      expect(response.body).not_to include("hidden@v1", "financial", "spend money")
    end
  end

  it "presents a request with plain-English wording and no raw keys" do
    request = authorization_request
    request.authorization_items.create!(item_attributes.merge(effects: [ "communication" ], decisive_rule: { "source" => "role_default", "policy" => "ask" }))

    get "/api/v1/app/permission_requests"

    presentation = JSON.parse(response.body).fetch("requests").first.fetch("presentation")
    expect(presentation).to include("statement" => "Publish a status update", "consequences" => [ "send a message" ],
      "why_approval_required" => "Agents of this kind need your approval before doing this.")
    expect(presentation.to_json).not_to match(/communication\.chat|send@v1|role_default/)
  end

  def authorization_request(deduplication_key: "permission-inbox-spec")
    ChatPendingAction.create!(request_kind: "authorization_request", user:, repository:, origin: job,
      subject: user, runtime_role: "implementer", purpose: "Publish a status update",
      deduplication_key:)
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
