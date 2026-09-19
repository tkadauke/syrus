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
        "PageDown" => "\e[6~"
      }.each do |key, sequence|
        client.input(type: "key", key: key)

        expect(relay.next_control).to eq("type" => "input", "data" => sequence)
      end
    end

    it "raises UnsupportedInput for an unrecognized key with no text/data" do
      expect { client.input(type: "keyboard", key: "F13") }.to raise_error(described_class::UnsupportedInput)
    end

    it "sends a resize frame for positive cols/rows" do
      client.input(type: "resize", cols: 120, rows: 40)

      expect(relay.next_control).to eq("type" => "resize", "cols" => 120, "rows" => 40)
    end

    it "accepts 'columns' as an alias for cols" do
      client.input(type: "resize", columns: 80, rows: 24)

      expect(relay.next_control).to eq("type" => "resize", "cols" => 80, "rows" => 24)
    end

    it "raises UnsupportedInput for non-positive resize dimensions" do
      expect { client.input(type: "resize", cols: 0, rows: 24) }.to raise_error(described_class::UnsupportedInput)
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
