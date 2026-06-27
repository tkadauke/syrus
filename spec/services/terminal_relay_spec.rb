require "rails_helper"
require "socket"

RSpec.describe TerminalRelay do
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
    Timeout.timeout(2) { sleep 0.01 until session.reload.relay_ready? }
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

    socket.write("from tcp")
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
end
