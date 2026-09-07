require "rails_helper"

RSpec.describe SyrusBrowser::SnapshotTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:session) { instance_double(SyrusBrowser::Session, close: nil) }
  let(:text_response) do
    { "result" => { "content" => [ { "type" => "text", "text" => "accessibility tree" } ] } }
  end

  before do
    SyrusBrowser::SessionRegistry.session_factory = ->(_session_key) { session }
  end

  after { SyrusBrowser::SessionRegistry.reset! }

  it "declares the browser_snapshot tool name" do
    expect(described_class.tool_name).to eq("browser_snapshot")
  end

  it "opts in to artifact capture" do
    expect(described_class.captures_artifact?).to be true
  end

  context "in the workflow Run path (visual_review)" do
    let(:run) { instance_double(Run, id: 7) }
    let(:ctx) { { run_id: 7 } }

    before do
      allow(Mcp::Tools).to receive(:run_from_context).with(ctx).and_return(run)
      allow(session).to receive(:call_tool).and_return(text_response)
    end

    it "returns text content unchanged and never persists anything (no images to capture)" do
      expect(ChatMediaLibrary).not_to receive(:materialize_captured_image!)

      response = described_class.call(server_context: ctx)

      expect(response).not_to be_error
      expect(response.content).to eq([ { type: "text", text: "accessibility tree" } ])
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

    before { runtime_session }

    it "does not persist anything when the upstream response has no image content" do
      allow(session).to receive(:call_tool).and_return(text_response)

      expect { described_class.call(server_context: { chat_session: chat_session }) }
        .not_to(change { chat_session.chat_attachments.count })
    end

    it "files an image capture as chat media when the upstream response includes one" do
      allow(session).to receive(:call_tool).and_return(
        { "result" => { "content" => [
          { "type" => "text", "text" => "accessibility tree" },
          { "type" => "image", "data" => "base64data", "mimeType" => "image/png" }
        ] } }
      )

      expect { described_class.call(server_context: { chat_session: chat_session }) }
        .to change { chat_session.chat_attachments.count }.by(1)
    end
  end
end
