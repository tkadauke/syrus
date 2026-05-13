require "rails_helper"

RSpec.describe "SyrusChatMcp canvas tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::ReadSceneTool,
        SyrusChatMcp::DrawShapeTool,
        SyrusChatMcp::DrawTextTool,
        SyrusChatMcp::DrawArrowTool,
        SyrusChatMcp::MoveElementTool,
        SyrusChatMcp::DeleteElementTool,
        SyrusChatMcp::ClearCanvasTool,
        SyrusChatMcp::UpdateSceneTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def jsonrpc(method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(name, arguments = {})
    jsonrpc("tools/call", params: { name: name, arguments: arguments })
  end

  def payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def expect_canvas_broadcast
    expect(Turbo::StreamsChannel).to receive(:broadcast_replace_later_to).with(
      "chat_session_#{chat_session.id}_whiteboard",
      hash_including(target: "chat_session_#{chat_session.id}_whiteboard")
    )
  end

  def draw_shape(type: "rectangle", x: 10, y: 20, width: 100, height: 60, **attrs)
    call_tool("draw_shape", { type: type, x: x, y: y, width: width, height: height }.merge(attrs))
  end

  def minimal_element(index)
    { "id" => "shape-#{index}", "type" => "rectangle" }
  end

  it "read_scene returns the empty scene without rasterization or mutation logging" do
    response = call_tool("read_scene")

    expect(response[:result][:isError]).to be_falsey
    expect(payload(response)).to eq(version: 0, elements: [])
    expect(chat_session.reload.whiteboard).to be_nil
    expect(chat_session.messages).to be_empty
  end

  it "draw_shape appends a server-id shape, increments the version, broadcasts, and logs tool use" do
    expect_canvas_broadcast

    response = draw_shape(type: "sticky", label: "Plan", color: "#fef08a")

    id = payload(response).fetch(:id)
    whiteboard = chat_session.reload.whiteboard
    element = whiteboard.elements.first
    expect(response[:result][:isError]).to be_falsey
    expect(id).to match(/\A[0-9A-Z_a-z-]{21}\z/)
    expect(whiteboard.version).to eq(1)
    expect(whiteboard.last_edited_at).to be_present
    expect(element).to include("id" => id, "type" => "sticky", "label" => "Plan", "backgroundColor" => "#fef08a")
    expect(chat_session.messages.last).to have_attributes(role: "tool_use", tool_name: "draw_shape")
  end

  it "draw_text appends a text element and logs the structured args" do
    expect_canvas_broadcast

    response = call_tool("draw_text", content: "Hello", x: 3, y: 4, font_size: 24)

    element = chat_session.reload.whiteboard.elements.first
    expect(response[:result][:isError]).to be_falsey
    expect(element).to include("type" => "text", "text" => "Hello", "fontSize" => 24)
    expect(chat_session.messages.last.content).to include("content" => "Hello", "font_size" => 24)
  end

  it "draw_arrow binds both arrow endpoints and both endpoint shapes" do
    from_id = payload(draw_shape(x: 0, y: 0, width: 100, height: 50)).fetch(:id)
    to_id = payload(draw_shape(type: "ellipse", x: 300, y: 100, width: 80, height: 40)).fetch(:id)
    expect_canvas_broadcast

    response = call_tool("draw_arrow", from_id: from_id, to_id: to_id, label: "flows")

    arrow_id = payload(response).fetch(:id)
    elements = chat_session.reload.whiteboard.elements
    arrow = elements.find { |element| element["id"] == arrow_id }
    from = elements.find { |element| element["id"] == from_id }
    to = elements.find { |element| element["id"] == to_id }
    expect(response[:result][:isError]).to be_falsey
    expect(arrow).to include(
      "type" => "arrow",
      "startBinding" => { "elementId" => from_id, "focus" => 0, "gap" => 1 },
      "endBinding" => { "elementId" => to_id, "focus" => 0, "gap" => 1 },
      "label" => "flows"
    )
    expect(from.fetch("boundElements")).to include("id" => arrow_id, "type" => "arrow")
    expect(to.fetch("boundElements")).to include("id" => arrow_id, "type" => "arrow")
  end

  it "move_element updates position and recalibrates bound arrows so endpoints follow dragged shapes" do
    from_id = payload(draw_shape(x: 0, y: 0, width: 100, height: 50)).fetch(:id)
    to_id = payload(draw_shape(x: 300, y: 100, width: 100, height: 50)).fetch(:id)
    arrow_id = payload(call_tool("draw_arrow", from_id: from_id, to_id: to_id)).fetch(:id)
    expect_canvas_broadcast

    response = call_tool("move_element", id: from_id, x: 50, y: 60)

    elements = chat_session.reload.whiteboard.elements
    from = elements.find { |element| element["id"] == from_id }
    arrow = elements.find { |element| element["id"] == arrow_id }
    expect(response[:result][:isError]).to be_falsey
    expect(from).to include("x" => 50.0, "y" => 60.0)
    expect(arrow["x"]).to eq(100.0)
    expect(arrow["y"]).to eq(85.0)
    expect(arrow["points"].last).to eq([ 250.0, 40.0 ])
  end

  it "delete_element removes the element and logs the mutation" do
    id = payload(draw_shape).fetch(:id)
    expect_canvas_broadcast

    response = call_tool("delete_element", id: id)

    expect(response[:result][:isError]).to be_falsey
    expect(chat_session.reload.whiteboard.elements).to be_empty
    expect(chat_session.messages.last).to have_attributes(role: "tool_use", tool_name: "delete_element")
  end

  it "clear_canvas empties the scene" do
    draw_shape
    call_tool("draw_text", content: "Note", x: 5, y: 5)
    expect_canvas_broadcast

    response = call_tool("clear_canvas")

    expect(response[:result][:isError]).to be_falsey
    expect(chat_session.reload.whiteboard.elements).to be_empty
  end

  it "update_scene replaces the elements array" do
    replacement = [
      { "id" => "shape-1", "type" => "rectangle", "x" => 1, "y" => 2, "width" => 3, "height" => 4 }
    ]
    expect_canvas_broadcast

    response = call_tool("update_scene", elements: replacement)

    expect(response[:result][:isError]).to be_falsey
    expect(chat_session.reload.whiteboard.elements).to eq(replacement)
    expect(chat_session.messages.last).to have_attributes(role: "tool_use", tool_name: "update_scene")
  end

  it "rejects append tools when the whiteboard is at the element limit" do
    chat_session.create_whiteboard!(
      scene_json: { "elements" => Array.new(Whiteboard::MAX_ELEMENTS) { |index| minimal_element(index) } }
    )

    responses = [
      draw_shape,
      call_tool("draw_text", content: "Blocked", x: 1, y: 2),
      call_tool("draw_arrow", from_id: "shape-0", to_id: "shape-1")
    ]

    responses.each do |response|
      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to eq(Whiteboard.element_limit_message)
    end
    expect(chat_session.reload.whiteboard.elements.size).to eq(Whiteboard::MAX_ELEMENTS)
    expect(chat_session.messages).to be_empty
  end

  it "rejects raw scene replacements beyond the element limit" do
    response = call_tool(
      "update_scene",
      elements: Array.new(Whiteboard::MAX_ELEMENTS + 1) { |index| minimal_element(index) }
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to eq(Whiteboard.element_limit_message)
    expect(chat_session.reload.whiteboard).to be_nil
    expect(chat_session.messages).to be_empty
  end

  it "drives a high-level sequence from read to mutation and back to read" do
    expect(payload(call_tool("read_scene"))).to eq(version: 0, elements: [])
    first_id = payload(draw_shape(x: 0, y: 0, width: 20, height: 20)).fetch(:id)
    second_id = payload(draw_shape(type: "diamond", x: 100, y: 0, width: 20, height: 20)).fetch(:id)
    arrow_id = payload(call_tool("draw_arrow", from_id: first_id, to_id: second_id)).fetch(:id)

    call_tool("move_element", id: second_id, x: 120, y: 10)
    call_tool("delete_element", id: arrow_id)
    final_scene = payload(call_tool("read_scene"))

    expect(final_scene.fetch(:version)).to eq(5)
    expect(final_scene.fetch(:elements).map { |element| element.fetch(:id) }).to contain_exactly(first_id, second_id)
    expect(final_scene.fetch(:elements).find { |element| element.fetch(:id) == second_id }).to include(x: 120.0, y: 10.0)
  end

  it "returns clean tool errors for unsupported shape types and malformed raw elements" do
    bad_shape = call_tool("draw_shape", type: "triangle", x: 0, y: 0, width: 10, height: 10)
    bad_update = call_tool("update_scene", elements: [ { "id" => "bad", "type" => "bogus" } ])

    expect(bad_shape[:result][:isError]).to be(true)
    expect(bad_shape[:result][:content].first[:text]).to match(/type must/)
    expect(bad_update[:result][:isError]).to be(true)
    expect(bad_update[:result][:content].first[:text]).to match(/unsupported element type/)
  end
end
