require "rails_helper"

RSpec.describe Mcp::Tools::SaveCanvasTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments = {})
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "save_canvas", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "returns an empty-canvas result without creating a snapshot" do
    response = nil

    expect {
      response = call_tool(name: "Empty plan")
    }.not_to change(WhiteboardSnapshot, :count)

    expect(response[:result][:isError]).to be_falsey
    expect(payload(response)).to eq(saved: false, reason: "canvas is empty")
  end

  it "saves a non-empty canvas as a manual snapshot" do
    chat_session.create_whiteboard!(
      scene_json: {
        "elements" => [ { "id" => "box-1", "type" => "rectangle" }, { "id" => "note-1", "type" => "text" } ],
        "appState" => { "viewBackgroundColor" => "#ffffff" },
        "files" => {}
      },
      version: 7
    )

    response = nil
    expect {
      response = call_tool(name: "Planning board")
    }.to change(WhiteboardSnapshot, :count).by(1)

    snapshot = WhiteboardSnapshot.first
    expect(response[:result][:isError]).to be_falsey
    expect(payload(response)).to include(
      saved: true,
      snapshot_id: snapshot.id,
      name: "Planning board",
      element_count: 2
    )
    expect(snapshot).to have_attributes(
      chat_session: chat_session,
      snapshot_kind: "manual",
      element_count: 2,
      name: "Planning board"
    )
    expect(snapshot.scene_json).to eq(
      "elements" => [ { "id" => "box-1", "type" => "rectangle" }, { "id" => "note-1", "type" => "text" } ],
      "appState" => { "viewBackgroundColor" => "#ffffff" },
      "files" => {}
    )
  end
end
