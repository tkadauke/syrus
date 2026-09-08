require "rails_helper"

RSpec.describe SyrusBrowser::ArtifactSinks do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:png_bytes) { "\x89PNG\r\n\x1a\n".b }

  describe SyrusBrowser::ArtifactSinks::Null do
    it "does nothing and returns nil" do
      expect(described_class.new.capture(bytes: png_bytes, content_type: "image/png", title: "x")).to be_nil
    end

    it "never touches ChatMediaLibrary" do
      expect(ChatMediaLibrary).not_to receive(:materialize_captured_image!)
      described_class.new.capture(bytes: png_bytes, content_type: "image/png", title: "x")
    end
  end

  describe SyrusBrowser::ArtifactSinks::ChatMedia do
    it "materializes a chat media Document via ChatMediaLibrary" do
      sink = described_class.new(chat_session)

      expect(ChatMediaLibrary).to receive(:materialize_captured_image!).with(
        chat_session, bytes: png_bytes, content_type: "image/png", title: "browser_screenshot capture"
      )

      sink.capture(bytes: png_bytes, content_type: "image/png", title: "browser_screenshot capture")
    end

    it "actually creates the Document + ChatAttachment end to end" do
      sink = described_class.new(chat_session)

      document = sink.capture(bytes: png_bytes, content_type: "image/png", title: "Screenshot")

      expect(document).to be_a(Document)
      expect(chat_session.chat_attachments.reload.map(&:attachable)).to include(document)
    end

    it "is a no-op when there is no chat session (defensive fallback)" do
      sink = described_class.new(nil)

      expect(ChatMediaLibrary).not_to receive(:materialize_captured_image!)
      expect(sink.capture(bytes: png_bytes, content_type: "image/png", title: "x")).to be_nil
    end

    it "stamps the runtime session's latest_frame_url/at when given a runtime_session" do
      repository_for_session = repository
      runtime_session = RuntimeSession.create!(repository: repository_for_session, chat_session: chat_session, workspace_ref: "a", provider_key: "browser", display_name: "Browser", state: "running")
      sink = described_class.new(chat_session, runtime_session: runtime_session)

      document = sink.capture(bytes: png_bytes, content_type: "image/png", title: "Screenshot")

      runtime_session.reload
      expect(runtime_session.latest_frame_url).to eq("/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{runtime_session.id}/frame")
      expect(runtime_session.latest_frame_at).to be_present
      expect(runtime_session.metadata["latest_frame_document_id"]).to eq(document.id)
    end

    it "does not touch any runtime session when none is given" do
      sink = described_class.new(chat_session)

      expect { sink.capture(bytes: png_bytes, content_type: "image/png", title: "x") }.not_to raise_error
    end

    it "surfaces a captured Runtime Session screenshot through the core list_chat_media MCP tool as a chat_image, with no dedicated media source needed" do
      runtime_session = RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "browser", display_name: "Browser", state: "running")
      sink = described_class.new(chat_session, runtime_session: runtime_session)
      document = sink.capture(bytes: png_bytes, content_type: "image/png", title: "Runtime capture")

      server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ Mcp::Tools::ListChatMediaTool ],
        server_context: { chat_session: chat_session }
      )
      raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_chat_media", arguments: {} } }.to_json)
      result = JSON.parse(raw, symbolize_names: true)
      payload = JSON.parse(result.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)

      expect(payload[:chat_images]).to contain_exactly(
        include(id: "chat_image:#{document.id}", kind: "chat_image", filename: document.filename, content_type: "image/png")
      )
    end
  end
end
