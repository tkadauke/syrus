require "rails_helper"

RSpec.describe RuntimeTerminal::RelayClient do
  let(:user) { Factories.user }

  def terminal_session(relay_address: nil)
    Terminal::Session.create!(
      user: user,
      workflow: nil,
      name: "Runtime Terminal",
      working_directory: "/workspace/chat-1",
      relay_address: relay_address,
      started_at: 1.minute.ago
    )
  end

  describe "#initialize" do
    it "raises ConnectionError when the terminal session has no relay address yet" do
      session = terminal_session(relay_address: nil)

      expect { described_class.new(session) }.to raise_error(described_class::ConnectionError, /not ready/)
    end

    it "raises ConnectionError when the relay address does not parse as host:port" do
      session = terminal_session(relay_address: "not-a-valid-address")

      expect { described_class.new(session) }.to raise_error(described_class::ConnectionError)
    end

    it "raises ConnectionError when nothing is listening at the relay address" do
      session = terminal_session(relay_address: "127.0.0.1:1")

      expect { described_class.new(session) }.to raise_error(described_class::ConnectionError)
    end

    it "authenticates with the terminal session's auth token and drains the initial replay" do
      relay = RuntimeTerminalFakeRelay.new(replay: "welcome\n")
      session = terminal_session(relay_address: relay.address)

      client = described_class.new(session)

      expect(relay.auth_payload).to eq("token" => session.auth_token)
      expect(client.inspect_scrollback).to eq("welcome\n")
    ensure
      client&.close
      relay&.stop
    end
  end

  describe "#inspect_scrollback" do
    it "accumulates output frames received after connecting" do
      relay = RuntimeTerminalFakeRelay.new(replay: "boot\n")
      session = terminal_session(relay_address: relay.address)
      client = described_class.new(session)

      relay.write_output("more output")

      expect(client.inspect_scrollback).to eq("boot\nmore output")
    ensure
      client&.close
      relay&.stop
    end
  end

  describe "#inspect_screen" do
    it "applies replay and subsequent output to one authoritative screen" do
      relay = RuntimeTerminalFakeRelay.new(replay: "old\rNEW")
      session = terminal_session(relay_address: relay.address)
      client = described_class.new(session)
      relay.write_output("\e[2;1H\e[38;2;10;20;30mcolor")

      snapshot = client.inspect_screen

      expect(snapshot).to include(kind: "terminal_screen", generation: 2, cols: 80, rows: 24)
      expect(snapshot.fetch(:lines).first).to eq("NEW")
      expect(snapshot.fetch(:lines).second).to eq("color")
    ensure
      client&.close
      relay&.stop
    end

    it "continues generation from a replaced relay client" do
      relay = RuntimeTerminalFakeRelay.new(replay: "restored")
      session = terminal_session(relay_address: relay.address)
      client = described_class.new(session, generation: 7)

      expect(client.inspect_screen.fetch(:generation)).to eq(8)
    ensure
      client&.close
      relay&.stop
    end

    it "bounds retained raw output" do
      stub_const("RuntimeTerminal::RelayClient::MAX_SCROLLBACK_BYTES", 8)
      relay = RuntimeTerminalFakeRelay.new(replay: "0123456789")
      client = described_class.new(terminal_session(relay_address: relay.address))

      expect(client.inspect_scrollback).to eq("23456789")
    ensure
      client&.close
      relay&.stop
    end

    it "raises a connection error after close while preserving its generation" do
      relay = RuntimeTerminalFakeRelay.new(replay: "ready")
      client = described_class.new(terminal_session(relay_address: relay.address))
      generation = client.screen_generation

      client.close

      expect { client.inspect_screen }.to raise_error(described_class::ConnectionError)
      expect(client.screen_generation).to eq(generation)
    ensure
      client&.close
      relay&.stop
    end
  end


  describe "screen synchronization" do
    it "waits for a later generation and visible text without sleeping" do
      relay = RuntimeTerminalFakeRelay.new(replay: "prompt")
      client = described_class.new(terminal_session(relay_address: relay.address))
      generation = client.screen_generation
      writer = Thread.new { relay.write_output(" ready") }

      result = client.inspect_screen(after_generation: generation, wait_for_text: "ready", timeout_seconds: 1)

      expect(result).to include(settled: true, generation: generation + 1)
      expect(result.fetch(:lines).first).to eq("prompt ready")
      writer.join
    ensure
      writer&.join
      client&.close
      relay&.stop
    end

    it "returns the latest screen with settled false at the bounded timeout" do
      relay = RuntimeTerminalFakeRelay.new(replay: "prompt")
      client = described_class.new(terminal_session(relay_address: relay.address))

      result = client.inspect_screen(wait_for_text: "missing", timeout_seconds: 0.01)

      expect(result).to include(settled: false)
    ensure
      client&.close
      relay&.stop
    end

    it "keeps concurrent input and inspection within their own timeout budgets" do
      relay = RuntimeTerminalFakeRelay.new(replay: "prompt")
      client = described_class.new(terminal_session(relay_address: relay.address))
      long_wait = Thread.new { client.inspect_screen(wait_for_text: "missing", timeout_seconds: 0.3) }
      Timeout.timeout(1) { Thread.pass until long_wait.status == "sleep" }

      input_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(client.input(type: "stdin", data: "x")).to be(true)
      input_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - input_started_at

      inspect_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = client.inspect_screen(wait_for_text: "also missing", timeout_seconds: 0.02)
      inspect_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - inspect_started_at

      expect(input_elapsed).to be < 0.15
      expect(inspect_elapsed).to be < 0.15
      expect(result).to include(settled: false)
    ensure
      long_wait&.join
      client&.close
      relay&.stop
    end

    it "returns compact styled runs only when requested" do
      relay = RuntimeTerminalFakeRelay.new(replay: "\e[31mred\e[0m plain")
      client = described_class.new(terminal_session(relay_address: relay.address))

      plain = client.inspect_screen
      styled = client.inspect_screen(include_styles: true)

      expect(plain).not_to have_key(:styled_runs)
      expect(styled.fetch(:styled_runs).first).to include(
        include(text: "red", foreground: { mode: "ansi", value: 1 }),
        include(text: " plain", foreground: nil)
      )
    ensure
      client&.close
      relay&.stop
    end
  end

  describe "#closed?" do
    it "is false for a freshly connected client" do
      relay = RuntimeTerminalFakeRelay.new
      session = terminal_session(relay_address: relay.address)
      client = described_class.new(session)

      expect(client.closed?).to be false
    ensure
      client&.close
      relay&.stop
    end

    it "is true after #close" do
      relay = RuntimeTerminalFakeRelay.new
      session = terminal_session(relay_address: relay.address)
      client = described_class.new(session)

      client.close

      expect(client.closed?).to be true
    ensure
      relay&.stop
    end
  end

  describe "#input" do
    let(:relay) { RuntimeTerminalFakeRelay.new }
    let(:session) { terminal_session(relay_address: relay.address) }
    let(:client) { described_class.new(session) }

    after do
      client.close
      relay.stop
    end

    it "sends stdin data verbatim" do
      client.input(type: "stdin", data: "whoami\n")

      expect(relay.next_control).to eq("type" => "input", "data" => "whoami\n")
    end

    it "sends literal keyboard text when data/text is present" do
      client.input(type: "keyboard", text: "hello")

      expect(relay.next_control).to eq("type" => "input", "data" => "hello")
    end

    it "maps named keys to their terminal escape sequences" do
      {
        "Enter" => "\r",
        "Tab" => "\t",
        "Backspace" => "\x7f",
        "Escape" => "\e",
        "ArrowUp" => "\e[A",
        "ArrowDown" => "\e[B",
        "Delete" => "\e[3~",
        "Home" => "\e[H",
        "End" => "\e[F",
        "PageUp" => "\e[5~",
        "PageDown" => "\e[6~",
        "Shift+Tab" => "\e[Z",
        "F1" => "\eOP",
        "F4" => "\eOS",
        "F5" => "\e[15~",
        "F12" => "\e[24~"
      }.each do |key, sequence|
        client.input(type: "key", key: key)

        expect(relay.next_control).to eq("type" => "input", "data" => sequence)
      end
    end

    it "maps Ctrl chords and structured modifiers to control bytes" do
      [
        [ { type: "key", key: "Ctrl+C" }, "\x03" ],
        [ { type: "key", key: "d", modifiers: [ "ctrl" ] }, "\x04" ],
        [ { type: "key", key: "L", ctrl: true }, "\x0c" ],
        [ { type: "key", key: "Tab", shift: true }, "\e[Z" ],
        [ { type: "key", key: "Ctrl+[" }, "\e" ],
        [ { type: "key", key: "Ctrl+Space" }, "\x00" ]
      ].each do |event, sequence|
        client.input(event)

        expect(relay.next_control).to eq("type" => "input", "data" => sequence)
      end
    end

    it "raises UnsupportedInput for an unsupported Ctrl chord" do
      expect { client.input(type: "key", key: "Ctrl+F1") }
        .to raise_error(described_class::UnsupportedInput, /unsupported Ctrl combination/)
    end

    it "raises UnsupportedInput for an unrecognized key with no text/data" do
      expect { client.input(type: "keyboard", key: "F13") }.to raise_error(described_class::UnsupportedInput)
    end

    it "sends a resize frame for positive cols/rows" do
      client.input(type: "resize", cols: 120, rows: 40)

      expect(relay.next_control).to eq("type" => "resize", "cols" => 120, "rows" => 40)
      expect(client.inspect_screen).to include(cols: 120, rows: 40, generation: 1)
    end

    it "accepts 'columns' as an alias for cols" do
      client.input(type: "resize", columns: 80, rows: 24)

      expect(relay.next_control).to eq("type" => "resize", "cols" => 80, "rows" => 24)
    end

    it "does not resize the emulator when the relay write fails" do
      socket = client.instance_variable_get(:@socket)
      allow(socket).to receive(:write).and_raise(Errno::EPIPE)

      expect { client.input(type: "resize", cols: 120, rows: 40) }
        .to raise_error(described_class::ConnectionError)
      screen = client.instance_variable_get(:@screen)
      expect(screen.snapshot).to include(cols: 80, rows: 24, generation: 0)
    end

    it "raises UnsupportedInput for non-positive resize dimensions" do
      expect { client.input(type: "resize", cols: 0, rows: 24) }.to raise_error(described_class::UnsupportedInput)
    end

    it "rejects resize dimensions above the bounded screen maximum" do
      expect { client.input(type: "resize", cols: described_class::MAX_COLS + 1, rows: 24) }
        .to raise_error(described_class::UnsupportedInput, /exceeds maximum/)
      expect { client.input(type: "resize", cols: 80, rows: described_class::MAX_ROWS + 1) }
        .to raise_error(described_class::UnsupportedInput, /exceeds maximum/)
    end

    it "raises UnsupportedInput when resize is missing rows entirely" do
      expect { client.input(type: "resize", cols: 80) }.to raise_error(described_class::UnsupportedInput)
    end

    it "sends a press-then-release pair for a click" do
      client.input(type: "pointer", action: "click", x: 5, y: 10, button: "left")

      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<0;5;10M")
      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<3;5;10m")
    end

    it "sends only a press frame for mousedown" do
      client.input(type: "pointer", action: "mousedown", x: 3, y: 4, button: "right")

      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<2;3;4M")
    end

    it "sends only a release frame for mouseup" do
      client.input(type: "pointer", action: "mouseup", x: 3, y: 4)

      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<3;3;4m")
    end

    it "sends a drag frame (button code + 32) for mousemove" do
      client.input(type: "pointer", action: "mousemove", x: 7, y: 8, button: "middle")

      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<33;7;8M")
    end

    it "sends the wheel-up sequence for wheel_up" do
      client.input(type: "pointer", action: "wheel_up", x: 1, y: 1)

      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<64;1;1M")
    end

    it "sends the wheel-down sequence for wheel_down" do
      client.input(type: "pointer", action: "wheel_down", x: 1, y: 1)

      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<65;1;1M")
    end

    it "resolves a generic wheel event's direction from delta_y" do
      client.input(type: "wheel", x: 1, y: 1, delta_y: 3)

      expect(relay.next_control).to eq("type" => "input", "data" => "\e[<65;1;1M")
    end

    it "raises UnsupportedInput for a pointer event with non-positive coordinates" do
      expect { client.input(type: "pointer", action: "click", x: 0, y: 5) }
        .to raise_error(described_class::UnsupportedInput)
    end

    it "raises UnsupportedInput for an unrecognized pointer action" do
      expect { client.input(type: "pointer", action: "doubleclick", x: 1, y: 1) }
        .to raise_error(described_class::UnsupportedInput)
    end

    it "raises UnsupportedInput for an unrecognized button name" do
      expect { client.input(type: "pointer", action: "click", x: 1, y: 1, button: "stylus") }
        .to raise_error(described_class::UnsupportedInput)
    end

    it "raises UnsupportedInput for a completely unrecognized event type" do
      expect { client.input(type: "touch", x: 1, y: 1) }.to raise_error(described_class::UnsupportedInput)
    end

    it "raises ConnectionError when writing to an already-closed client" do
      client.close

      expect { client.input(type: "stdin", data: "x") }.to raise_error(described_class::ConnectionError)
    end
  end

  describe "#close" do
    it "is idempotent" do
      relay = RuntimeTerminalFakeRelay.new
      session = terminal_session(relay_address: relay.address)
      client = described_class.new(session)

      expect { client.close; client.close }.not_to raise_error
    ensure
      relay&.stop
    end
  end
end
