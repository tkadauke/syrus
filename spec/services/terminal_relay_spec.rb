require "rails_helper"
require "socket"
require "timeout"

RSpec.describe TerminalRelay do
  RELAY_READY_TIMEOUT = 15

  class FakePtyInput
    attr_reader :winsize_calls

    def initialize(io)
      @io = io
      @winsize_calls = []
    end

    def write(data)
      @io.write(data)
    end

    def winsize=(value)
      @winsize_calls << value
    end

    def close
      @io.close unless @io.closed?
    end

    def closed?
      @io.closed?
    end
  end

  let(:user) { Factories.user }
  let(:session) do
    TerminalSession.create!(
      user: user,
      name: "scratch",
      working_directory: Rails.root.to_s,
      started_at: Time.current,
      auth_token: "token-123"
    )
  end
  let(:pid) { 987_654_321 }

  def build_relay
    pty_out_read, child_output_write = IO.pipe
    pty_input_read, pty_input_write = IO.pipe
    pty_in = FakePtyInput.new(pty_input_write)
    relay = described_class.new(session: session, command: [ "bash" ], env: { "TERM" => "xterm" })

    allow(relay).to receive(:spawn_pty) do |&block|
      block.call(pty_out_read, pty_in, pid)
    end

    [ relay, child_output_write, pty_input_read, pty_in ]
  end

  def run_relay(relay)
    thread = Thread.new { relay.run }
    thread[:terminal_relay_spec] = true
    Timeout.timeout(RELAY_READY_TIMEOUT) do
      until session.reload.relay_ready?
        raise "TerminalRelay exited before recording relay_address" unless thread.alive?

        sleep 0.01
      end
    end
    thread
  end

  def connect_and_auth(token = session.auth_token)
    host, port = session.reload.relay_address.split(":")
    socket = TCPSocket.new(host, port.to_i)
    socket.write({ token: token }.to_json)
    socket.write("\n")
    socket
  end

  def read_available(io)
    Timeout.timeout(2) do
      loop do
        ready = IO.select([ io ], nil, nil, 0.05)
        return io.read_nonblock(16 * 1024) if ready
      end
    end
  end

  def relay_for_host
    described_class.new(session: session, command: [ "bash" ], env: {})
  end

  def with_terminal_host(value)
    previous = ENV["SYRUS_TERMINAL_HOST"]
    value.nil? ? ENV.delete("SYRUS_TERMINAL_HOST") : ENV["SYRUS_TERMINAL_HOST"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("SYRUS_TERMINAL_HOST") : ENV["SYRUS_TERMINAL_HOST"] = previous
  end

  after do
    Thread.list.each do |thread|
      next if thread == Thread.current
      next unless thread[:terminal_relay_spec]

      thread.kill
      thread.join
    end
  end

  it "accepts the auth token and relays bytes bidirectionally" do
    relay, child_output_write, pty_input_read, = build_relay
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket = connect_and_auth

    child_output_write.write("from pty")
    expect(read_available(socket)).to eq("from pty")

    socket.write({ type: "input", data: "from tcp" }.to_json)
    socket.write("\n")
    expect(read_available(pty_input_read)).to eq("from tcp")

    socket.close
    thread.join(2)
    expect(session.reload).to be_finished
    expect(session.outcome).to eq("exited")
  ensure
    socket&.close unless socket&.closed?
    child_output_write&.close unless child_output_write&.closed?
    pty_input_read&.close unless pty_input_read&.closed?
  end

  it "rejects an invalid auth token and closes the connection" do
    relay, child_output_write, pty_input_read, = build_relay
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket = connect_and_auth("wrong-token")

    expect { socket.readpartial(1) }.to raise_error(EOFError)
    thread.join(2)
    expect(session.reload).to be_finished
  ensure
    socket&.close unless socket&.closed?
    child_output_write&.close unless child_output_write&.closed?
    pty_input_read&.close unless pty_input_read&.closed?
  end

  it "allows a second client to reconnect after the first disconnects" do
    relay, child_output_write, pty_input_read, = build_relay
    pty_alive = true
    allow(relay).to receive(:pty_alive?).with(pid) { pty_alive }
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    first_socket = connect_and_auth

    first_socket.close
    second_socket = connect_and_auth

    expect(session.reload).to be_running

    second_socket.write({ type: "input", data: "from second client" }.to_json)
    second_socket.write("\n")
    expect(read_available(pty_input_read)).to eq("from second client")

    child_output_write.write("after reconnect")
    expect(read_available(second_socket)).to eq("after reconnect")

    pty_alive = false
    second_socket.close
    thread.join(2)
    expect(session.reload).to be_finished
    expect(session.outcome).to eq("exited")
  ensure
    first_socket&.close unless first_socket&.closed?
    second_socket&.close unless second_socket&.closed?
    child_output_write&.close unless child_output_write&.closed?
    pty_input_read&.close unless pty_input_read&.closed?
  end

  it "finalizes the session when the reconnect timeout expires" do
    stub_const("#{described_class}::RECONNECT_TIMEOUT", 0.05)
    relay, child_output_write, pty_input_read, = build_relay
    allow(relay).to receive(:pty_alive?).with(pid).and_return(true)
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket = connect_and_auth

    socket.close

    thread.join(2)
    expect(thread).not_to be_alive
    expect(session.reload).to be_finished
    expect(session.outcome).to eq("exited")
  ensure
    socket&.close unless socket&.closed?
    child_output_write&.close unless child_output_write&.closed?
    pty_input_read&.close unless pty_input_read&.closed?
  end

  it "finalizes immediately when the PTY exits between connections" do
    stub_const("#{described_class}::RECONNECT_TIMEOUT", 60)
    relay, child_output_write, pty_input_read, = build_relay
    allow(relay).to receive(:pty_alive?).with(pid).and_return(false)
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket = connect_and_auth

    socket.close

    thread.join(2)
    expect(thread).not_to be_alive
    expect(session.reload).to be_finished
    expect(session.outcome).to eq("exited")
  ensure
    socket&.close unless socket&.closed?
    child_output_write&.close unless child_output_write&.closed?
    pty_input_read&.close unless pty_input_read&.closed?
  end

  it "applies resize frames without forwarding them to the PTY input" do
    relay, child_output_write, pty_input_read, pty_in = build_relay
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket = connect_and_auth

    socket.write({ type: "resize", cols: 220, rows: 50 }.to_json)
    socket.write("\n")

    Timeout.timeout(2) { sleep 0.01 until pty_in.winsize_calls.any? }
    expect(pty_in.winsize_calls).to include([ 50, 220 ])
    expect(IO.select([ pty_input_read ], nil, nil, 0.05)).to be_nil

    socket.close
    thread.join(2)
  ensure
    socket&.close unless socket&.closed?
    child_output_write&.close unless child_output_write&.closed?
    pty_input_read&.close unless pty_input_read&.closed?
  end

  it "polls finished_at, terminates the PTY pid, and finalizes the session" do
    stub_const("#{described_class}::KILL_POLL_INTERVAL_SECONDS", 0.05)
    relay, child_output_write, pty_input_read, = build_relay
    finished = false
    allow(session).to receive(:reload) do
      finished ? instance_double(TerminalSession, finished_at: Time.current) : session
    end
    expect(Process).to receive(:kill).with("TERM", pid).at_least(:once).and_return(1)

    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket = connect_and_auth
    finished = true

    thread.join(2)
    expect(thread).not_to be_alive
    allow(session).to receive(:reload).and_call_original
    expect(session.reload).to be_finished
    expect(session.outcome).to eq("exited")
  ensure
    socket&.close unless socket&.closed?
    child_output_write&.close unless child_output_write&.closed?
    pty_input_read&.close unless pty_input_read&.closed?
  end

  it "uses SYRUS_TERMINAL_HOST when set" do
    with_terminal_host("worker") do
      expect(relay_for_host.relay_host).to eq("worker")
    end
  end

  it "falls back to localhost when SYRUS_TERMINAL_HOST is not set" do
    with_terminal_host(nil) do
      expect(relay_for_host.relay_host).to eq("127.0.0.1")
    end
  end

  it "falls back to localhost when SYRUS_TERMINAL_HOST is blank" do
    with_terminal_host("") do
      expect(relay_for_host.relay_host).to eq("127.0.0.1")
    end
  end
end
