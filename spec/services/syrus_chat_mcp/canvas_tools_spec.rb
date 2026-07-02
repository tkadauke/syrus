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
        SyrusChatMcp::DrawLineTool,
        SyrusChatMcp::DrawArrowTool,
        SyrusChatMcp::DrawFreedrawTool,
        SyrusChatMcp::DrawFrameTool,
        SyrusChatMcp::DrawEmbedTool,
        SyrusChatMcp::DrawImageTool,
        SyrusChatMcp::MoveElementTool,
        SyrusChatMcp::DeleteElementTool,
        SyrusChatMcp::SaveCanvasTool,
        SyrusChatMcp::ClearCanvasTool,
        SyrusChatMcp::LoadCanvasTool,
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
    # Each canvas mutation may also write a ChatMessage. Set up a
    # permissive allow so message-tail events pass through and the
    # strict expect below still asserts the whiteboard event.
    allow(AppEvents).to receive(:broadcast)
    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "chat",
      id: chat_session.id,
      changed: [ "whiteboard" ],
      payload: hash_including("elements" => kind_of(Array), "version" => kind_of(Integer))
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
    expect(payload(response)).to eq(version: 0, elements: [], appState: {}, files: {})
    expect(chat_session.reload.whiteboard).to be_nil
    expect(chat_session.messages).to be_empty
  end

  it "draw_shape appends a server-id shape, increments the version, and broadcasts" do
    expect_canvas_broadcast

    response = draw_shape(type: "sticky", label: "Plan", color: "#fef08a")

    id = payload(response).fetch(:id)
    whiteboard = chat_session.reload.whiteboard
    shape, label = whiteboard.elements
    expect(response[:result][:isError]).to be_falsey
    expect(id).to match(/\A[0-9A-Z_a-z-]{21}\z/)
    expect(whiteboard.version).to eq(1)
    expect(whiteboard.last_edited_at).to be_present
    expect(shape).to include("id" => id, "type" => "rectangle", "backgroundColor" => "#fef08a", "strokeColor" => "#854d0e")
    expect(shape).not_to have_key("label")
    # Labels are a paired text element bound via containerId; the
    # container's boundElements references it back so Excalidraw
    # treats the pair as one logical shape.
    expect(shape.fetch("boundElements")).to include("id" => label.fetch("id"), "type" => "text")
    expect(label).to include(
      "type" => "text",
      "text" => "Plan",
      "containerId" => id,
      "textAlign" => "center",
      "verticalAlign" => "middle"
    )
  end

  it "draw_text appends a text element" do
    expect_canvas_broadcast

    response = call_tool("draw_text", content: "Hello", x: 3, y: 4, font_size: 24)

    element = chat_session.reload.whiteboard.elements.first
    expect(response[:result][:isError]).to be_falsey
    expect(element).to include("type" => "text", "text" => "Hello", "originalText" => "Hello", "fontSize" => 24)
  end

  it "draw_line appends a polyline or unbound arrow" do
    expect_canvas_broadcast

    response = call_tool(
      "draw_line",
      type: "arrow",
      x: 10,
      y: 20,
      points: [ [ 0, 0 ], [ 30, 10 ], [ 60, 40 ] ],
      end_arrowhead: "triangle"
    )

    element = chat_session.reload.whiteboard.elements.first
    expect(response[:result][:isError]).to be_falsey
    expect(element).to include(
      "type" => "arrow",
      "points" => [ [ 0.0, 0.0 ], [ 30.0, 10.0 ], [ 60.0, 40.0 ] ],
      "startBinding" => nil,
      "endBinding" => nil,
      "endArrowhead" => "triangle",
      "elbowed" => false
    )
  end

  it "draw_freedraw appends a freehand path" do
    expect_canvas_broadcast

    response = call_tool(
      "draw_freedraw",
      x: 5,
      y: 6,
      points: [ { x: 0, y: 0 }, { x: 10, y: 8 } ],
      pressures: [ 0.2, 0.7 ],
      simulate_pressure: false
    )

    element = chat_session.reload.whiteboard.elements.first
    expect(response[:result][:isError]).to be_falsey
    expect(element).to include(
      "type" => "freedraw",
      "points" => [ [ 0.0, 0.0 ], [ 10.0, 8.0 ] ],
      "pressures" => [ 0.2, 0.7 ],
      "simulatePressure" => false
    )
  end

  it "draw_frame appends frame-like elements" do
    expect_canvas_broadcast

    response = call_tool("draw_frame", type: "magicframe", x: 0, y: 0, width: 400, height: 300, name: "Plan")

    element = chat_session.reload.whiteboard.elements.first
    expect(response[:result][:isError]).to be_falsey
    expect(element).to include("type" => "magicframe", "name" => "Plan", "width" => 400.0, "height" => 300.0)
  end

  it "draw_embed appends embeddable iframe-like elements" do
    expect_canvas_broadcast

    response = call_tool("draw_embed", type: "iframe", link: "https://example.com/demo", x: 1, y: 2, width: 300, height: 180)

    element = chat_session.reload.whiteboard.elements.first
    expect(response[:result][:isError]).to be_falsey
    expect(element).to include("type" => "iframe", "link" => "https://example.com/demo")
  end

  it "draw_image stores an image element and its BinaryFiles entry" do
    expect_canvas_broadcast

    response = call_tool("draw_image", data_url: "data:image/png;base64,abc", x: 1, y: 2, width: 30, height: 40)

    whiteboard = chat_session.reload.whiteboard
    element = whiteboard.elements.first
    file_id = element.fetch("fileId")
    expect(response[:result][:isError]).to be_falsey
    expect(element).to include("type" => "image", "status" => "saved", "scale" => [ 1, 1 ], "crop" => nil)
    expect(whiteboard.files.fetch(file_id)).to include(
      "id" => file_id,
      "dataURL" => "data:image/png;base64,abc",
      "mimeType" => "image/png"
    )
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

  it "delete_element removes the element" do
    id = payload(draw_shape).fetch(:id)
    expect_canvas_broadcast

    response = call_tool("delete_element", id: id)

    expect(response[:result][:isError]).to be_falsey
    expect(chat_session.reload.whiteboard.elements).to be_empty
  end

  it "clear_canvas saves a snapshot before emptying the scene" do
    draw_shape
    call_tool("draw_text", content: "Note", x: 5, y: 5)
    expect_canvas_broadcast

    response = nil
    expect {
      response = call_tool("clear_canvas")
    }.to change(WhiteboardSnapshot, :count).by(1)

    snapshot = WhiteboardSnapshot.first
    expect(response[:result][:isError]).to be_falsey
    expect(payload(response)).to include(cleared: true, snapshot_id: snapshot.id)
    expect(snapshot).to have_attributes(
      chat_session: chat_session,
      snapshot_kind: "auto_clear",
      element_count: 2
    )
    expect(snapshot.scene_json.fetch("elements").map { |element| element.fetch("type") }).to contain_exactly("rectangle", "text")
    expect(chat_session.reload.whiteboard.elements).to be_empty
  end

  it "clear_canvas skips snapshot creation for an empty scene" do
    expect_canvas_broadcast

    response = nil
    expect {
      response = call_tool("clear_canvas")
    }.not_to change(WhiteboardSnapshot, :count)

    expect(response[:result][:isError]).to be_falsey
    expect(payload(response)).to include(cleared: true, snapshot_id: nil)
    expect(chat_session.reload.whiteboard.elements).to be_empty
  end

  it "load_canvas merges snapshot elements with fresh ids and merged files" do
    existing_id = payload(draw_shape).fetch(:id)
    snapshot = WhiteboardSnapshot.create_from_scene!(
      chat_session: chat_session,
      kind: "manual",
      scene: {
        "elements" => [
          {
            "id" => "snapshot-box",
            "type" => "rectangle",
            "boundElements" => [ { "id" => "snapshot-label", "type" => "text" } ]
          },
          {
            "id" => "snapshot-label",
            "type" => "text",
            "containerId" => "snapshot-box",
            "text" => "Loaded"
          },
          {
            "id" => "snapshot-image",
            "type" => "image",
            "fileId" => "snapshot-file"
          }
        ],
        "appState" => { "viewBackgroundColor" => "#fff7ed" },
        "files" => {
          "snapshot-file" => { "id" => "snapshot-file", "dataURL" => "data:image/png;base64,snapshot", "mimeType" => "image/png" }
        }
      }
    )
    expect_canvas_broadcast

    response = call_tool("load_canvas", snapshot_id: snapshot.id)

    whiteboard = chat_session.reload.whiteboard
    loaded_elements = whiteboard.elements.reject { |element| element.fetch("id") == existing_id }
    loaded_box = loaded_elements.find { |element| element["type"] == "rectangle" }
    loaded_label = loaded_elements.find { |element| element["type"] == "text" }
    expect(response[:result][:isError]).to be_falsey
    expect(payload(response)).to include(
      loaded: true,
      snapshot_id: snapshot.id,
      mode: "merge",
      elements_added: 3,
      auto_saved_snapshot_id: nil
    )
    expect(whiteboard.elements.first.fetch("id")).to eq(existing_id)
    expect(loaded_elements.map { |element| element.fetch("id") }).not_to include("snapshot-box", "snapshot-label", "snapshot-image")
    expect(loaded_box.fetch("boundElements")).to include("id" => loaded_label.fetch("id"), "type" => "text")
    expect(loaded_label.fetch("containerId")).to eq(loaded_box.fetch("id"))
    expect(whiteboard.files).to include("snapshot-file" => include("dataURL" => "data:image/png;base64,snapshot"))
  end

  it "load_canvas replace mode auto-saves the current canvas and replaces scene and files" do
    current_element_id = payload(draw_shape(type: "ellipse")).fetch(:id)
    snapshot = WhiteboardSnapshot.create_from_scene!(
      chat_session: chat_session,
      kind: "manual",
      scene: {
        "elements" => [ { "id" => "replacement", "type" => "rectangle" } ],
        "appState" => { "viewBackgroundColor" => "#ecfeff" },
        "files" => { "replacement-file" => { "id" => "replacement-file", "dataURL" => "data:image/png;base64,replacement" } }
      }
    )
    expect_canvas_broadcast

    response = nil
    expect {
      response = call_tool("load_canvas", snapshot_id: snapshot.id, mode: "replace")
    }.to change(WhiteboardSnapshot, :count).by(1)

    auto_saved_snapshot = WhiteboardSnapshot.where(snapshot_kind: "auto_before_load").first
    whiteboard = chat_session.reload.whiteboard
    expect(response[:result][:isError]).to be_falsey
    expect(payload(response)).to include(
      loaded: true,
      snapshot_id: snapshot.id,
      mode: "replace",
      elements_added: 1,
      auto_saved_snapshot_id: auto_saved_snapshot.id
    )
    expect(auto_saved_snapshot.scene_json.fetch("elements").map { |element| element.fetch("id") }).to contain_exactly(current_element_id)
    expect(whiteboard.elements).to eq([ { "id" => "replacement", "type" => "rectangle" } ])
    expect(whiteboard.app_state).to eq("viewBackgroundColor" => "#ecfeff")
    expect(whiteboard.files).to eq("replacement-file" => { "id" => "replacement-file", "dataURL" => "data:image/png;base64,replacement" })
  end

  it "load_canvas enforces the element limit before merging" do
    chat_session.create_whiteboard!(
      scene_json: { "elements" => Array.new(Whiteboard::MAX_ELEMENTS) { |index| minimal_element(index) } }
    )
    snapshot = WhiteboardSnapshot.create_from_scene!(
      chat_session: chat_session,
      kind: "manual",
      scene: { "elements" => [ { "id" => "extra", "type" => "rectangle" } ] }
    )

    response = call_tool("load_canvas", snapshot_id: snapshot.id)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to eq(Whiteboard.element_limit_message)
    expect(chat_session.reload.whiteboard.elements.size).to eq(Whiteboard::MAX_ELEMENTS)
  end

  it "load_canvas scopes snapshots to the current chat session" do
    other_session = ChatSession.create!(user: user, repository: repository)
    snapshot = WhiteboardSnapshot.create_from_scene!(
      chat_session: other_session,
      kind: "manual",
      scene: { "elements" => [ { "id" => "other", "type" => "rectangle" } ] }
    )

    expect {
      SyrusChatMcp::LoadCanvasTool.call(snapshot_id: snapshot.id, server_context: { chat_session: chat_session })
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "update_scene replaces the elements array" do
    replacement = [
      { "id" => "line-1", "type" => "line", "x" => 1, "y" => 2, "width" => 3, "height" => 4, "points" => [ [ 0, 0 ], [ 3, 4 ] ] },
      { "id" => "image-1", "type" => "image", "x" => 10, "y" => 20, "width" => 30, "height" => 40, "fileId" => "file-1" }
    ]
    files = { "file-1" => { "id" => "file-1", "dataURL" => "data:image/png;base64,abc", "mimeType" => "image/png" } }
    expect_canvas_broadcast

    response = call_tool("update_scene", elements: replacement, appState: { viewBackgroundColor: "#fff" }, files: files)

    expect(response[:result][:isError]).to be_falsey
    expect(chat_session.reload.whiteboard.elements).to eq(replacement)
    expect(chat_session.reload.whiteboard.app_state).to eq("viewBackgroundColor" => "#fff")
    expect(chat_session.reload.whiteboard.files).to eq(files)
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
    expect(payload(call_tool("read_scene"))).to eq(version: 0, elements: [], appState: {}, files: {})
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

  it "draws sticky shapes as yellow rectangles" do
    expect_canvas_broadcast

    response = draw_shape(type: "sticky", x: 50, y: 50, width: 150, height: 100)

    element = chat_session.reload.whiteboard.elements.first
    expect(response[:result][:isError]).to be_falsey
    expect(element).to include(
      "type" => "rectangle",
      "backgroundColor" => "#fef08a",
      "strokeColor" => "#854d0e"
    )
  end

  describe "SyrusChatMcp::Canvas" do
    it "ELEMENT_TYPES does not include sticky" do
      expect(SyrusChatMcp::Canvas::ELEMENT_TYPES).not_to include("sticky")
    end

    it "validate_elements! raises on a sticky element" do
      elements = [ { "id" => "s1", "type" => "sticky" } ]
      expect {
        SyrusChatMcp::Canvas.validate_elements!(elements)
      }.to raise_error(ArgumentError, /unsupported element type: sticky/)
    end

    it "update_scene rejects sticky elements via validate_elements!" do
      bad_update = call_tool("update_scene", elements: [ { "id" => "sticky-1", "type" => "sticky" } ])

      expect(bad_update[:result][:isError]).to be(true)
      expect(bad_update[:result][:content].first[:text]).to match(/unsupported element type: sticky/)
    end
  end
end
