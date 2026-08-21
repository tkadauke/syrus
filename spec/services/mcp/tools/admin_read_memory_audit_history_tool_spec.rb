require "rails_helper"

RSpec.describe Mcp::Tools::AdminReadMemoryAuditHistoryTool do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:admin_chat_session) { ChatSession.create!(user: admin, repository: Factories.repository(user: admin)) }
  let(:non_admin_chat_session) { ChatSession.create!(user: owner, repository: Factories.repository(user: owner)) }

  def payload_from(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "has tool_name admin_read_memory_audit_history" do
    expect(described_class.tool_name).to eq("admin_read_memory_audit_history")
  end

  it "rejects non-admin chat contexts" do
    memory = ChatMemory.create!(user: owner, kind: "feedback", scope: "global", content: "Hi.")

    response = described_class.call(memory_id: memory.id, server_context: { chat_session: non_admin_chat_session })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("Unauthorized")
  end

  it "returns an error for an unknown memory" do
    response = described_class.call(memory_id: 0, server_context: { chat_session: admin_chat_session })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not found")
  end

  it "returns the full audit trail for a created-then-updated memory, oldest first" do
    memory = ChatMemory.create!(user: owner, kind: "feedback", scope: "global", content: "Original.")
    memory.update!(content: "Revised.", kind: "project_fact")

    response = described_class.call(memory_id: memory.id, server_context: { chat_session: admin_chat_session })

    expect(response).not_to be_error
    payload = payload_from(response)
    expect(payload[:memory_id]).to eq(memory.id)
    expect(payload[:deleted]).to be(false)
    expect(payload[:audit_events].map { |e| e[:event_type] }).to eq(%w[created updated])
    updated_event = payload[:audit_events].last
    expect(updated_event[:previous_content]).to eq("Original.")
    expect(updated_event[:new_content]).to eq("Revised.")
    expect(updated_event[:previous_kind]).to eq("feedback")
    expect(updated_event[:new_kind]).to eq("project_fact")
  end

  it "includes soft-deleted memories and marks the response deleted" do
    memory = ChatMemory.create!(user: owner, kind: "feedback", scope: "global", content: "Stale.")
    memory.soft_delete_by!(admin)

    response = described_class.call(memory_id: memory.id, server_context: { chat_session: admin_chat_session })

    expect(response).not_to be_error
    payload = payload_from(response)
    expect(payload[:deleted]).to be(true)
    expect(payload[:audit_events].map { |e| e[:event_type] }).to eq(%w[created deleted])
    deleted_event = payload[:audit_events].last
    expect(deleted_event[:actor_kind]).to eq("user")
    expect(deleted_event[:actor_user_id]).to eq(admin.id)
    expect(deleted_event[:previous_content]).to eq("Stale.")
  end
end
