require "rails_helper"

RSpec.describe SyrusBrowser::ScreenshotTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:session) { instance_double(SyrusBrowser::Session, close: nil) }
  let(:image_response) do
    { "result" => { "content" => [ { "type" => "image", "data" => "base64data", "mimeType" => "image/png" } ] } }
  end

  before do
    SyrusBrowser::SessionRegistry.session_factory = ->(_session_key) { session }
  end

  after { SyrusBrowser::SessionRegistry.reset! }

  it "declares the browser_screenshot tool name" do
    expect(described_class.tool_name).to eq("browser_screenshot")
  end

  it "opts in to artifact capture" do
    expect(described_class.captures_artifact?).to be true
  end

  context "in the workflow Run path (visual_review)" do
    let(:run) { instance_double(Run, id: 7) }
    let(:ctx) { { run_id: 7 } }

    before do
      allow(Mcp::Tools).to receive(:run_from_context).with(ctx).and_return(run)
      allow(session).to receive(:call_tool).and_return(image_response)
    end

    it "returns the image content unchanged (byte-for-byte) and does not persist anything" do
      expect(ChatMediaLibrary).not_to receive(:materialize_captured_image!)

      response = described_class.call(target: "e1", server_context: ctx)

      expect(response).not_to be_error
      expect(response.content).to eq([ { type: "image", data: "base64data", mimeType: "image/png" } ])
    end
  end

  context "in a Coding Mode chat's runtime session path" do
    let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
    let(:runtime_session) do
      RuntimeSession.create!(
        repository: repository, chat_session: chat_session,
        workspace_ref: "/workspace", provider_key: "browser", display_name: "Browser", state: "running"
      )
    end

    before do
      runtime_session
      allow(session).to receive(:call_tool).and_return(image_response)
    end

    it "still returns the image content to the caller" do
      response = described_class.call(target: "e1", server_context: { chat_session: chat_session })

      expect(response).not_to be_error
      expect(response.content).to eq([ { type: "image", data: "base64data", mimeType: "image/png" } ])
    end

    it "also files the screenshot as a chat-visible Document" do
      expect { described_class.call(target: "e1", server_context: { chat_session: chat_session }) }
        .to change { chat_session.chat_attachments.count }.by(1)

      document = chat_session.chat_attachments.reload.last.attachable
      expect(document).to be_a(Document)
      expect(document.content_type).to eq("image/png")
    end

    it "does not fail the tool call if capture fails" do
      allow(ChatMediaLibrary).to receive(:materialize_captured_image!).and_raise("boom")

      response = described_class.call(target: "e1", server_context: { chat_session: chat_session })

      expect(response).not_to be_error
    end
  end
end
