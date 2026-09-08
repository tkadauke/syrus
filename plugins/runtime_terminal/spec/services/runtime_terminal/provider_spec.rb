require "rails_helper"

RSpec.describe RuntimeTerminal::Provider do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:runtime_session) do
    RuntimeSession.create!(
      repository: repository,
      chat_session: chat_session,
      workspace_ref: "/workspace/chat-1",
      provider_key: "cli_tui",
      display_name: "Terminal",
      state: "starting"
    )
  end
  let(:provider) { described_class.new }

  after do
    described_class.reset_relay_clients!
  end

  describe ".provider_key and .display_name" do
    it "identifies itself as DOC-17's CLI/TUI provider" do
      expect(described_class.provider_key).to eq("cli_tui")
      expect(described_class.display_name).to eq("Terminal")
    end
  end

  describe ".detect" do
    it "does not auto-detect until repository runtime config exists" do
      expect(described_class.detect(repository, workspace_path: "/workspace/chat-1")).to be false
    end
  end

  describe ".capabilities" do
    it "advertises terminal input and scrollback inspection capabilities" do
      expect(described_class.capabilities(repository, {})).to eq(
        stream: "none",
        input: %w[keyboard stdin pointer resize],
        inspect: [ "scrollback" ],
        build: [ "none" ],
        artifacts: [ "logs" ]
      )
    end
  end

  describe "#start_session" do
    it "creates and maps a Terminal::Session for the chat workspace and enqueues the terminal job" do
      allow(TerminalSessionJob).to receive(:perform_later)

      metadata = provider.start_session(
        runtime_session.workspace_ref,
        runtime_session: runtime_session,
        chat_session: chat_session
      )

      terminal_session = Terminal::Session.find(metadata.fetch(:terminal_session_id))
      expect(terminal_session).to have_attributes(
        user_id: user.id,
        workflow_id: nil,
        name: "Runtime Terminal",
        working_directory: "/workspace/chat-1",
        outcome: nil
      )
      expect(terminal_session.started_at).to be_present
      expect(RuntimeTerminal::SessionLink.find_by!(runtime_session: runtime_session).terminal_session)
        .to eq(terminal_session)
      expect(TerminalSessionJob).to have_received(:perform_later).with(terminal_session.id)
    end
  end

  describe "#inspect" do
    it "returns the relay replay buffer and output received after connection" do
      relay = RuntimeTerminalFakeRelay.new(replay: "booted\n")
      terminal_session = Terminal::Session.create!(
        user: user,
        workflow: nil,
        name: "Runtime Terminal",
        working_directory: runtime_session.workspace_ref,
        relay_address: relay.address,
        started_at: 1.minute.ago
      )
      RuntimeTerminal::SessionLink.create!(runtime_session: runtime_session, terminal_session: terminal_session)

      first = provider.inspect(runtime_session.id)
      relay.write_output("prompt> ")
      second = provider.inspect(runtime_session.id)

      expect(relay.auth_payload).to eq("token" => terminal_session.auth_token)
      expect(first).to include(kind: "terminal_scrollback", scrollback: "booted\n", bytes: 7)
      expect(second).to include(scrollback: "booted\nprompt> ", bytes: 15)
    ensure
      relay&.stop
    end

    it "waits for TerminalSessionJob to publish the relay address before connecting" do
      relay = RuntimeTerminalFakeRelay.new(replay: "ready after reload\n")
      terminal_session = Terminal::Session.create!(
        user: user,
        workflow: nil,
        name: "Runtime Terminal",
        working_directory: runtime_session.workspace_ref,
        relay_address: nil,
        started_at: 1.minute.ago
      )
      RuntimeTerminal::SessionLink.create!(runtime_session: runtime_session, terminal_session: terminal_session)

      allow(provider).to receive(:sleep).with(described_class::RELAY_ADDRESS_POLL_INTERVAL)
      allow(terminal_session).to receive(:reload) do
        terminal_session.relay_address = relay.address
        terminal_session
      end
      allow(provider).to receive(:terminal_session_for).with(runtime_session).and_return(terminal_session)

      expect(provider.inspect(runtime_session.id)).to include(scrollback: "ready after reload\n")
      expect(provider).to have_received(:sleep).with(described_class::RELAY_ADDRESS_POLL_INTERVAL)
    ensure
      relay&.stop
    end
  end

  describe "#input" do
    it "rejects input without an active agent control lease before connecting to the relay" do
      relay = RuntimeTerminalFakeRelay.new
      terminal_session = Terminal::Session.create!(
        user: user,
        workflow: nil,
        name: "Runtime Terminal",
        working_directory: runtime_session.workspace_ref,
        relay_address: relay.address,
        started_at: 1.minute.ago
      )
      RuntimeTerminal::SessionLink.create!(runtime_session: runtime_session, terminal_session: terminal_session)

      expect(provider.input(runtime_session.id, { type: "stdin", data: "whoami\n" }))
        .to include(error: "lease_required")
      expect(relay.auth_payload).to be_nil
    ensure
      relay&.stop
    end

    it "writes stdin, resize, and pointer control frames to the mapped relay socket" do
      relay = RuntimeTerminalFakeRelay.new
      terminal_session = Terminal::Session.create!(
        user: user,
        workflow: nil,
        name: "Runtime Terminal",
        working_directory: runtime_session.workspace_ref,
        relay_address: relay.address,
        started_at: 1.minute.ago
      )
      RuntimeTerminal::SessionLink.create!(runtime_session: runtime_session, terminal_session: terminal_session)
      RuntimeControlLease.acquire!(
        runtime_session: runtime_session,
        owner: "agent",
        mode: "input",
        reason: "drive terminal"
      )

      expect(provider.input(runtime_session.id, { type: "stdin", data: "whoami\n" })).to eq(delivered: true)
      expect(provider.input(runtime_session.id, { type: "resize", cols: 100, rows: 40 })).to eq(delivered: true)
      expect(provider.input(runtime_session.id, { type: "pointer", action: "click", x: 12, y: 5, button: "left" }))
        .to eq(delivered: true)

      expect(relay.next_control).to eq("type" => "input", "data" => "whoami\n")
      expect(relay.next_control).to eq("type" => "resize", "cols" => 100, "rows" => 40)
      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<0;12;5M")
      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<3;12;5m")
    ensure
      relay&.stop
    end
  end

  describe "#stop_session" do
    it "marks the mapped terminal session killed when it is still running" do
      terminal_session = Terminal::Session.create!(
        user: user,
        workflow: nil,
        name: "Runtime Terminal",
        working_directory: runtime_session.workspace_ref,
        started_at: 1.minute.ago
      )
      RuntimeTerminal::SessionLink.create!(runtime_session: runtime_session, terminal_session: terminal_session)

      expect(provider.stop_session(runtime_session.id)).to be true

      expect(terminal_session.reload.outcome).to eq("killed")
      expect(terminal_session.finished_at).to be_present
    end

    it "leaves an already finished terminal session unchanged" do
      finished_at = 5.minutes.ago
      terminal_session = Terminal::Session.create!(
        user: user,
        workflow: nil,
        name: "Runtime Terminal",
        working_directory: runtime_session.workspace_ref,
        started_at: 10.minutes.ago,
        finished_at: finished_at,
        outcome: "exited"
      )
      RuntimeTerminal::SessionLink.create!(runtime_session: runtime_session, terminal_session: terminal_session)

      provider.stop_session(runtime_session.id)

      expect(terminal_session.reload.outcome).to eq("exited")
      expect(terminal_session.finished_at.to_i).to eq(finished_at.to_i)
    end
  end

  describe "mapping cleanup" do
    before do
      PluginRecord.find_or_create_by!(name: "runtime_terminal").update!(enabled: true, disableable: true)
    end

    it "allows the runtime session to be destroyed without manual adapter cleanup" do
      terminal_session = Terminal::Session.create!(
        user: user,
        workflow: nil,
        name: "Runtime Terminal",
        working_directory: runtime_session.workspace_ref,
        started_at: 1.minute.ago
      )
      RuntimeTerminal::SessionLink.create!(runtime_session: runtime_session, terminal_session: terminal_session)

      expect { runtime_session.destroy! }.to change(RuntimeTerminal::SessionLink, :count).by(-1)
      expect(Terminal::Session.exists?(terminal_session.id)).to be true
    end

    it "allows the owning chat session to destroy its runtime sessions" do
      terminal_session = Terminal::Session.create!(
        user: user,
        workflow: nil,
        name: "Runtime Terminal",
        working_directory: runtime_session.workspace_ref,
        started_at: 1.minute.ago
      )
      RuntimeTerminal::SessionLink.create!(runtime_session: runtime_session, terminal_session: terminal_session)

      expect { chat_session.destroy! }.to change(RuntimeTerminal::SessionLink, :count).by(-1)
      expect(RuntimeSession.exists?(runtime_session.id)).to be false
      expect(Terminal::Session.exists?(terminal_session.id)).to be true
    end

    it "still cleans up after the adapter plugin is disabled" do
      PluginRecord.find_by!(name: "runtime_terminal").update!(enabled: false)
      terminal_session = Terminal::Session.create!(
        user: user,
        workflow: nil,
        name: "Runtime Terminal",
        working_directory: runtime_session.workspace_ref,
        started_at: 1.minute.ago
      )
      RuntimeTerminal::SessionLink.create!(runtime_session: runtime_session, terminal_session: terminal_session)

      expect { runtime_session.destroy! }.to change(RuntimeTerminal::SessionLink, :count).by(-1)
    end
  end
end
