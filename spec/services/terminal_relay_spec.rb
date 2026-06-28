require "rails_helper"
require "socket"
require "timeout"

RSpec.describe TerminalRelay do
  let(:user) { Factories.user }
  let(:session) do
    TerminalSession.create!(
      user: user,
      name: "scratch",
      working_directory: Rails.root.to_s,
      auth_token: "terminal-token",
      started_at: Time.current
    )
  end

  class FakeTerminalInput
    attr_reader :writes, :winsize_values

    def initialize
      @writes = []
      @winsize_values = []
      @closed = false
    end

    def write(value)
      @writes << value
    end

    def winsize=(value)
      @winsize_values << value
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  def wait_until
    Timeout.timeout(2) do
      loop do
        return if yield

        sleep 0.01
      end
    end
  end

  def connect_to_relay(token: session.auth_token)
    wait_until { session.reload.relay_address.present? }
    host, port = session.relay_address.split(":", 2)
    socket = TCPSocket.new(host, port.to_i)
    socket.puts({ token: token }.to_json)
    socket
  end

  around do |example|
    previous_host = ENV["SYRUS_TERMINAL_HOST"]
    ENV["SYRUS_TERMINAL_HOST"] = "127.0.0.1"
    example.run
  ensure
    ENV["SYRUS_TERMINAL_HOST"] = previous_host
  end

  it "relays PTY output to the socket and socket input to PTY stdin" do
    relay = described_class.new(
      session: session,
      command: [
        "ruby",
        "-e",
        "STDOUT.sync = true; puts 'ready'; while (line = STDIN.gets); puts \"echo:\#{line}\"; end"
      ],
      env: {}
    )
    relay_thread = Thread.new { relay.run }
    socket = connect_to_relay

    expect(socket.gets).to include("ready")

    socket.puts({ type: "input", data: "hello\n" }.to_json)

    echo = nil
    wait_until do
      echo = socket.gets
      echo&.include?("echo:hello")
    end
    expect(echo).to include("echo:hello")

    socket.close
    relay_thread.join(2)
    expect(session.reload).to be_finished
    expect(session.outcome).to eq("exited")
  ensure
    socket&.close unless socket&.closed?
    relay_thread&.kill if relay_thread&.alive?
  end

  it "rejects connections with the wrong auth token" do
    allow(PTY).to receive(:spawn)
    relay = described_class.new(session: session, command: [ "bash" ], env: {})
    relay_thread = Thread.new { relay.run }
    socket = connect_to_relay(token: "wrong-token")

    expect(relay_thread.value).to be(false)
    expect(PTY).not_to have_received(:spawn)
    expect(socket.gets).to be_nil
  ensure
    socket&.close unless socket&.closed?
    relay_thread&.kill if relay_thread&.alive?
  end

  it "applies resize frames to the PTY input" do
    fake_input = FakeTerminalInput.new
    pty_out, pty_writer = IO.pipe
    allow(PTY).to receive(:spawn).and_return([ pty_out, fake_input, 12_345 ])
    allow(Process).to receive(:kill)
    allow(Process).to receive(:wait)
    stub_const("#{described_class}::POLL_INTERVAL", 0.05)
    relay = described_class.new(session: session, command: [ "bash" ], env: {})
    relay_thread = Thread.new { relay.run }
    socket = connect_to_relay

    socket.puts({ type: "resize", cols: 132, rows: 43 }.to_json)

    wait_until { fake_input.winsize_values.include?([ 43, 132 ]) }
  ensure
    socket&.close unless socket&.closed?
    pty_writer&.close unless pty_writer&.closed?
    relay_thread&.join(1)
    relay_thread&.kill if relay_thread&.alive?
  end

  it "terminates the PTY when the session is killed while connected" do
    fake_input = FakeTerminalInput.new
    pty_out, pty_writer = IO.pipe
    allow(PTY).to receive(:spawn).and_return([ pty_out, fake_input, 12_345 ])
    allow(Process).to receive(:wait)
    kill_seen = false
    expect(Process).to receive(:kill).with("TERM", 12_345).at_least(:once) do
      kill_seen = true
    end
    stub_const("#{described_class}::POLL_INTERVAL", 0.05)
    relay = described_class.new(session: session, command: [ "bash" ], env: {})
    relay_thread = Thread.new { relay.run }
    socket = connect_to_relay

    session.update!(finished_at: Time.current, outcome: "killed")

    wait_until { kill_seen }
  ensure
    socket&.close unless socket&.closed?
    pty_writer&.close unless pty_writer&.closed?
    relay_thread&.join(1)
    relay_thread&.kill if relay_thread&.alive?
  end
end
