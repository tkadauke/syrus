require "rails_helper"

RSpec.describe "Smart permission decisions", type: :request do
  let(:owner) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "smart decision request spec") }
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "coworker.message@v1", operation: "coworker.message/message_coworker@v1", effects: %i[internal_write],
      risk: :medium, requestable_roles: [ "chat:coworker" ], defaults: { "chat:coworker" => :ask },
      maximum_autonomy: :permanent, authority_durations: %i[ invocation chat_session job permanent ],
      resource_scope: Permissions::ResourceScopeSchema.new(type: :none),
      classifier: ->(_arguments) { { operation: "coworker.message/message_coworker@v1", confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    assigned = coworker
    chat.define_singleton_method(:coworker) { assigned }
    allow(Permissions::Catalog).to receive(:descriptors) { [ descriptor ] }
    sign_in_as(owner)
  end

  after { scope.dispose }

  let(:action) do
    tool = Mcp::Sidecar.chat_tools(chat.reload, tier: :essential).find { |t| McpToolRegistry.tool_name_for(t) == "message_coworker" }
    payload = JSON.parse(tool.call(handle: "maya", text: "Hello", server_context: { chat_session: chat }).content.first.fetch(:text))
    chat.pending_actions.find(payload.fetch("pending_action_id")).tap do |pending|
      # The request records the durations its requesting descriptor offers;
      # mirror the catalog variant stubbed above onto it.
      pending.authorization_items.update_all(requested_durations: descriptor.authority_durations.map(&:to_s))
    end
  end
  let(:item) { action.authorization_items.find_by!(kind: "operation") }

  it "exposes the same smart option on the inbox and chat surfaces" do
    action
    get "/api/v1/app/permission_requests"
    inbox = JSON.parse(response.body).fetch("requests").find { |r| r.fetch("id") == action.id }.fetch("items").first.fetch("smart_option")

    get "/api/v1/app/chats/#{chat.id}"
    chat_item = JSON.parse(response.body).dig("pending_actions").find { |a| a.fetch("id") == action.id }.fetch("authorization_items").first

    expect(inbox).to include("kind" => "always_allow_similar", "duration" => "permanent")
    expect(chat_item.fetch("smart_option")).to eq(inbox)
    expect(chat_item.fetch("app_smart_decision_path")).to end_with("/authorization_items/#{item.id}/smart_decision")
  end

  it "applies the rule and approves the item from the inbox" do
    option = item && JSON.parse(Permissions::SmartDecision.new(request: action, item: item, user: owner).option.to_json)

    expect do
      post "/api/v1/app/permission_requests/#{action.id}/items/#{item.id}/smart_decision", params: { duration: "permanent", digest: option.fetch("digest") }
    end.to change(PermissionRule, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).fetch("request")).to include("id" => action.id, "state" => "confirming")
    expect(item.reload.resulting_authority).to be_a(PermissionRule)
  end

  it "applies from the chat endpoint and answers 409 for a stale or duplicate decision without creating rules" do
    option = Permissions::SmartDecision.new(request: action, item: item, user: owner).option
    path = "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}/authorization_items/#{item.id}/smart_decision"

    expect { post path, params: { duration: "permanent", digest: "stale" } }.not_to change(PermissionRule, :count)
    expect(response).to have_http_status(:conflict)
    expect(item.reload).to be_pending

    expect { post path, params: { duration: "permanent", digest: option.fetch(:digest) } }.to change(PermissionRule, :count).by(1)
    expect(response).to have_http_status(:ok)

    expect { post path, params: { duration: "permanent", digest: option.fetch(:digest) } }.not_to change(PermissionRule, :count)
    expect(response).to have_http_status(:conflict)
  end
end
