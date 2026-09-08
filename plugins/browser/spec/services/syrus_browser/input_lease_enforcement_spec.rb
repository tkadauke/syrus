require "rails_helper"

RSpec.describe "SyrusBrowser input-lease enforcement (DOC-17)" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:runtime_session) do
    RuntimeSession.create!(
      repository: repository, chat_session: chat_session,
      workspace_ref: "/workspace/chat-1", provider_key: "browser", display_name: "Browser", state: "running"
    )
  end
  let(:session) { instance_double(SyrusBrowser::Session, call_tool: { "result" => { "content" => [] } }, close: nil) }

  before { SyrusBrowser::SessionRegistry.session_factory = ->(_key) { session } }
  after { SyrusBrowser::SessionRegistry.reset! }

  describe "requires_input_lease?" do
    it "flags the pointer/keyboard input tools" do
      expect(SyrusBrowser::ClickTool.requires_input_lease?).to be true
      expect(SyrusBrowser::FillTool.requires_input_lease?).to be true
      expect(SyrusBrowser::HoverTool.requires_input_lease?).to be true
    end

    it "leaves navigation, observation, and lifecycle tools ungated" do
      expect(SyrusBrowser::NavigateTool.requires_input_lease?).to be false
      expect(SyrusBrowser::SnapshotTool.requires_input_lease?).to be false
      expect(SyrusBrowser::ScreenshotTool.requires_input_lease?).to be false
      expect(SyrusBrowser::ResizeTool.requires_input_lease?).to be false
      expect(SyrusBrowser::WaitForTool.requires_input_lease?).to be false
      expect(SyrusBrowser::CloseTool.requires_input_lease?).to be false
    end
  end

  describe "against a Coding Mode RuntimeSession" do
    it "rejects browser_click without an active agent input lease" do
      response = SyrusBrowser::ClickTool.call(target: "e1", server_context: { runtime_session: runtime_session })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("lease_required")
      expect(session).not_to have_received(:call_tool)
    end

    it "rejects browser_fill and browser_hover the same way" do
      fill_response = SyrusBrowser::FillTool.call(target: "e1", text: "hi", server_context: { runtime_session: runtime_session })
      hover_response = SyrusBrowser::HoverTool.call(target: "e1", server_context: { runtime_session: runtime_session })

      expect(fill_response).to be_error
      expect(fill_response.content.first[:text]).to include("lease_required")
      expect(hover_response).to be_error
      expect(hover_response.content.first[:text]).to include("lease_required")
      expect(session).not_to have_received(:call_tool)
    end

    it "allows browser_click once the agent holds an active input lease" do
      RuntimeControlLease.acquire!(runtime_session: runtime_session, owner: "agent", mode: "input", reason: "click a button")

      response = SyrusBrowser::ClickTool.call(target: "e1", server_context: { runtime_session: runtime_session })

      expect(response).not_to be_error
      expect(session).to have_received(:call_tool).with(name: "browser_click", arguments: { "target" => "e1" })
    end

    it "does not accept a build/lifecycle lease as a substitute for an input lease" do
      RuntimeControlLease.acquire!(runtime_session: runtime_session, owner: "agent", mode: "build", reason: "reloading")

      response = SyrusBrowser::ClickTool.call(target: "e1", server_context: { runtime_session: runtime_session })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("lease_required")
    end

    it "does not require a lease to navigate, since runtime_launch drives navigation without one" do
      response = SyrusBrowser::NavigateTool.call(url: "http://127.0.0.1:3001/", server_context: { runtime_session: runtime_session })

      expect(response).not_to be_error
      expect(session).to have_received(:call_tool).with(name: "browser_navigate", arguments: { "url" => "http://127.0.0.1:3001/" })
    end
  end

  describe "against the workflow Run path (visual_review)" do
    let(:run) { instance_double(Run, id: 99) }

    before { allow(Mcp::Tools).to receive(:run_from_context).and_return(run) }

    it "does not require a lease -- there is no Shared Control concept for a single-agent Run" do
      response = SyrusBrowser::ClickTool.call(target: "e1", server_context: { run_id: 99 })

      expect(response).not_to be_error
      expect(session).to have_received(:call_tool).with(name: "browser_click", arguments: { "target" => "e1" })
    end
  end
end
