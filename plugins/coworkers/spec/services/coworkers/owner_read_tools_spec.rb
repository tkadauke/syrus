require "rails_helper"

RSpec.describe "owner-scoped coworker read tools" do
  let(:owner) { Factories.user }
  let(:chat) { ChatSession.create!(user: owner) }
  let(:context) { { chat_session: chat } }

  def create_coworker(name:, handle:, owner_user: owner, **attributes)
    Coworkers::Coworker.create!({
      owner_user: owner_user, name: name, handle: handle,
      workspace_repo: "https://github.com/acme/workspace.git"
    }.merge(attributes))
  end

  def payload(response)
    JSON.parse(response.content.first.fetch(:text))
  end

  it "lists only the current owner's coworkers in deterministic name/id order" do
    second = create_coworker(name: "zoe", handle: "zoe")
    first = create_coworker(name: "Ada", handle: "ada")
    same_name = create_coworker(name: "ada", handle: "ada-two")
    create_coworker(name: "Hidden", handle: "hidden-owner-read", owner_user: Factories.user)

    response = Coworkers::McpTools::ListCoworkersTool.call(server_context: context)

    expect(payload(response).fetch("coworkers").pluck("id")).to eq([ first.id, same_name.id, second.id ])
  end

  it "lists every catalog grant with each coworker's policy, scope, and tools" do
    coworker = create_coworker(name: "Maya", handle: "maya-grant-list")
    descriptor = Coworkers::GrantCatalog::Descriptor.new(
      name: "database.read", label: "Read database", description: "Read it", default_policy: "confirm", maximum_policy: "auto",
      tools: [ "list_database_tables" ], scope_options_callback: ->(user:) { [ user.id ] },
      scope_label_callback: ->(value) { "Connection #{value}" }, valid_scope_callback: ->(value, user:) { value == user.id }
    )
    allow(Coworkers::GrantCatalog).to receive(:all).and_return([ descriptor ])
    coworker.grants.create!(capability: descriptor.name, approval_policy: "confirm", scope: owner.id)

    result = payload(Coworkers::McpTools::ListCoworkerGrantsTool.call(server_context: context)).fetch("coworkers").sole

    expect(result).to include("id" => coworker.id, "handle" => coworker.handle)
    expect(result.fetch("grants").sole).to include(
      "capability" => "database.read", "approval_policy" => "confirm", "scope" => owner.id,
      "scope_label" => "Connection #{owner.id}", "tools" => [ "list_database_tables" ]
    )
  end

  it "filters by state and bounded text across name, handle, and role summary" do
    create_coworker(name: "Ada", handle: "ada-filter", role_summary: "Security researcher")
    paused = create_coworker(name: "Maya", handle: "maya-filter", role_summary: "QA lead", state: "paused")

    response = Coworkers::McpTools::ListCoworkersTool.call(server_context: context, state: "paused", query: "QA", limit: 500)
    expect(payload(response)).to include("limit" => 50)
    expect(payload(response).fetch("coworkers").pluck("id")).to eq([ paused.id ])

    oversized = Coworkers::McpTools::ListCoworkersTool.call(server_context: context, query: "x" * 201)
    expect(oversized).to be_error
  end

  it "reads by owner-scoped numeric ID or handle without exposing another owner's record" do
    coworker = create_coworker(name: "Maya", handle: "maya-read", chat_provider: "codex", role_summary: "QA engineer")
    hidden = create_coworker(name: "Hidden", handle: "hidden-read", owner_user: Factories.user)

    by_id = Coworkers::McpTools::ReadCoworkerTool.call(server_context: context, coworker_id: coworker.id)
    by_handle = Coworkers::McpTools::ReadCoworkerTool.call(server_context: context, handle: "@MAYA-READ")
    foreign = Coworkers::McpTools::ReadCoworkerTool.call(server_context: context, coworker_id: hidden.id)

    expect(payload(by_id).dig("coworker", "id")).to eq(coworker.id)
    expect(payload(by_handle).dig("coworker", "id")).to eq(coworker.id)
    expect(foreign).to be_error
    expect(foreign.content.first.fetch(:text)).to eq("Error: coworker not found")
  end

  it "returns a compact dedicated configuration shape with grants and chats but no credentials" do
    coworker = create_coworker(name: "Maya", handle: "maya-shape", chat_model: "gpt-example")
    coworker.update_column(:workspace_repo, "https://oauth-secret@github.com/acme/workspace.git")
    coworker.grants.create!(capability: "workspace.files", approval_policy: "confirm", constraints: { "confirm_paths" => [ "SOUL.md" ] })
    main_chat = ChatSession.create!(user: owner, title: "Maya main")
    Coworkers::Chat.create!(coworker: coworker, chat_session: main_chat, role: "main")

    result = payload(Coworkers::McpTools::ReadCoworkerTool.call(server_context: context, handle: "maya-shape")).fetch("coworker")

    expect(result.keys).to match_array(%w[id name handle role_summary state appearance path main_chat model_configuration workspace grants chats active_schedules])
    expect(result.dig("model_configuration", "model")).to eq("value" => "gpt-example", "source" => "coworker")
    expect(result.dig("model_configuration", "effort", "source")).to eq("account_default")
    expect(result.dig("workspace", "home_branch")).to eq("coworkers/maya-shape")
    expect(result.dig("workspace", "repository")).to eq("https://github.com/acme/workspace.git")
    expect(result.fetch("grants").first).to include("approval_policy" => "confirm", "constraints" => { "confirm_paths" => [ "SOUL.md" ] })
    expect(result.fetch("chats").first).to include("role" => "main", "path" => "/chats/#{main_chat.id}")
    expect(result.to_json).not_to match(/oauth-secret|token|credential|password|authenticated_remote/i)
  end

  it "omits an authenticated non-GitHub workspace remote" do
    coworker = create_coworker(name: "Legacy", handle: "legacy-remote")
    coworker.update_column(:workspace_repo, "https://api-user:super-secret@example.com/org/repo.git")

    result = payload(
      Coworkers::McpTools::ReadCoworkerTool.call(server_context: context, coworker_id: coworker.id)
    ).fetch("coworker")

    expect(result.dig("workspace", "repository")).to be_nil
    expect(result.to_json).not_to include("api-user", "super-secret", "example.com")
  end

  it "requires exactly one reference" do
    expect(Coworkers::McpTools::ReadCoworkerTool.call(server_context: context)).to be_error
    expect(Coworkers::McpTools::ReadCoworkerTool.call(server_context: context, coworker_id: 1, handle: "maya")).to be_error
  end
end
