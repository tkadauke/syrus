require "rails_helper"

RSpec.describe SyrusChatMcp::ListChatMediaTool do
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

  def call_tool
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_chat_media", arguments: {} } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def create_snapshot(chat_session:, name: "My snapshot", element_count: 3)
    WhiteboardSnapshot.create!(
      chat_session: chat_session,
      name: name,
      scene_json: { "elements" => Array.new(element_count) { |i| { "id" => "el-#{i}" } }, "appState" => {} },
      snapshot_kind: "manual",
      element_count: element_count
    )
  end

  def create_chat_image(chat_session:, filename: "diagram.png", content_type: "image/png")
    doc = Document.new(kind: "file", attachable: user, user: user, content_type: content_type, filename: filename)
    doc.file.attach(io: StringIO.new("pixels"), filename: filename, content_type: content_type)
    doc.save!
    ChatAttachment.create!(
      chat_session: chat_session,
      attachable: doc,
      suppress_header_broadcast: true
    )
    doc
  end

  it "returns empty arrays and zero element count when no media exists" do
    result = payload(call_tool)

    expect(result[:snapshots]).to eq([])
    expect(result[:chat_images]).to eq([])
    expect(result[:whiteboard_element_count]).to eq(0)
  end

  it "returns snapshots with expected fields" do
    snapshot = create_snapshot(chat_session: chat_session, name: "Architecture plan", element_count: 5)

    result = payload(call_tool)

    expect(result[:snapshots].size).to eq(1)
    snap = result[:snapshots].first
    expect(snap[:id]).to eq("snapshot:#{snapshot.id}")
    expect(snap[:kind]).to eq("snapshot")
    expect(snap[:name]).to eq("Architecture plan")
    expect(snap[:element_count]).to eq(5)
    expect(snap[:created_at]).to be_present
  end

  it "returns chat images with expected fields" do
    doc = create_chat_image(chat_session: chat_session, filename: "diagram.png", content_type: "image/png")

    result = payload(call_tool)

    expect(result[:chat_images].size).to eq(1)
    img = result[:chat_images].first
    expect(img[:id]).to eq("chat_image:#{doc.id}")
    expect(img[:kind]).to eq("chat_image")
    expect(img[:filename]).to eq("diagram.png")
    expect(img[:content_type]).to eq("image/png")
  end

  it "does not return media from other chat sessions" do
    other_session = ChatSession.create!(user: user, repository: repository)
    create_snapshot(chat_session: other_session)
    create_chat_image(chat_session: other_session)

    result = payload(call_tool)

    expect(result[:snapshots]).to be_empty
    expect(result[:chat_images]).to be_empty
  end

  it "returns the current whiteboard element count" do
    chat_session.create_whiteboard!(
      scene_json: { "elements" => [ { "id" => "a" }, { "id" => "b" }, { "id" => "c" } ], "appState" => {}, "files" => {} },
      version: 1
    )

    result = payload(call_tool)

    expect(result[:whiteboard_element_count]).to eq(3)
  end

  it "excludes non-image document attachments" do
    doc = Document.new(kind: "file", attachable: user, user: user, content_type: "application/pdf", filename: "report.pdf")
    doc.file.attach(io: StringIO.new("pdf data"), filename: "report.pdf", content_type: "application/pdf")
    doc.save!
    ChatAttachment.create!(chat_session: chat_session, attachable: doc, suppress_header_broadcast: true)

    result = payload(call_tool)

    expect(result[:chat_images]).to be_empty
  end
end
