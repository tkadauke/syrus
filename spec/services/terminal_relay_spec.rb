require "rails_helper"
require "socket"
require "timeout"
require "base64"

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

  def read_json_frame(io)
    buffer = +""
    Timeout.timeout(2) do
      loop do
        ready = IO.select([ io ], nil, nil, 0.05)
        if ready
          chunk = io.read_nonblock(16 * 1024)
          buffer << chunk
          if (idx = buffer.index("\n"))
            return JSON.parse(buffer[0..idx])
          end
        end
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

  it "accepts the auth token and relays output as JSON frames" do
    relay, child_output_write, pty_input_read, = build_relay
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket = connect_and_auth

    # Sync: send input and wait for it to reach pty_input_read, confirming
    # the connection thread has joined @connections and any subsequent PTY
    # output will arrive as a live "output" frame rather than a replay frame.
    socket.write({ type: "input", data: "from tcp" }.to_json)
    socket.write("\n")
    expect(read_available(pty_input_read)).to eq("from tcp")

    child_output_write.write("from pty")
    frame = read_json_frame(socket)
    expect(frame["type"]).to eq("output")
    expect(Base64.decode64(frame["data"])).to eq("from pty")

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
    frame = read_json_frame(second_socket)
    expect(frame["type"]).to eq("output")
    expect(Base64.decode64(frame["data"])).to eq("after reconnect")

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

  it "broadcasts PTY output to all simultaneous clients" do
    relay, child_output_write, pty_input_read, = build_relay
    allow(relay).to receive(:pty_alive?).with(pid).and_return(true)
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket1 = connect_and_auth
    socket2 = connect_and_auth

    # Sync: confirm both sockets are in @connections before writing PTY output,
    # so both receive "output" frames rather than replay frames.
    socket1.write({ type: "input", data: "s1" }.to_json + "\n")
    socket2.write({ type: "input", data: "s2" }.to_json + "\n")
    Timeout.timeout(2) do
      buf = +""
      until buf.include?("s1") && buf.include?("s2")
        ready = IO.select([ pty_input_read ], nil, nil, 0.05)
        buf << pty_input_read.read_nonblock(16 * 1024) if ready
      end
    end

    child_output_write.write("broadcast")
    frame1 = read_json_frame(socket1)
    frame2 = read_json_frame(socket2)

    expect(frame1["type"]).to eq("output")
    expect(Base64.decode64(frame1["data"])).to eq("broadcast")
    expect(frame2["type"]).to eq("output")
    expect(Base64.decode64(frame2["data"])).to eq("broadcast")

    socket1.close
    socket2.close
    thread.join(2)
  ensure
    socket1&.close unless socket1&.closed?
    socket2&.close unless socket2&.closed?
    child_output_write&.close unless child_output_write&.closed?
    pty_input_read&.close unless pty_input_read&.closed?
  end

  it "sends the scrollback buffer as a replay frame to a late-joining client" do
    relay, child_output_write, _, = build_relay
    allow(relay).to receive(:pty_alive?).with(pid).and_return(true)
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket1 = connect_and_auth

    child_output_write.write("scrollback data")
    read_json_frame(socket1)  # Drain socket1 so scrollback is appended

    socket2 = connect_and_auth
    replay = read_json_frame(socket2)

    expect(replay["type"]).to eq("replay")
    expect(Base64.decode64(replay["data"])).to eq("scrollback data")

    socket1.close
    socket2.close
    thread.join(2)
  ensure
    socket1&.close unless socket1&.closed?
    socket2&.close unless socket2&.closed?
    child_output_write&.close unless child_output_write&.closed?
  end

  it "routes input from any connected client to the PTY" do
    relay, _, pty_input_read, = build_relay
    allow(relay).to receive(:pty_alive?).with(pid).and_return(true)
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket1 = connect_and_auth
    socket2 = connect_and_auth

    socket1.write({ type: "input", data: "from socket1" }.to_json)
    socket1.write("\n")
    expect(read_available(pty_input_read)).to eq("from socket1")

    socket2.write({ type: "input", data: "from socket2" }.to_json)
    socket2.write("\n")
    expect(read_available(pty_input_read)).to eq("from socket2")

    socket1.close
    socket2.close
    thread.join(2)
  ensure
    socket1&.close unless socket1&.closed?
    socket2&.close unless socket2&.closed?
    pty_input_read&.close unless pty_input_read&.closed?
  end

  it "applies the minimum of all connected clients' sizes when resizing" do
    relay, _, _, pty_in = build_relay
    allow(relay).to receive(:pty_alive?).with(pid).and_return(true)
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket1 = connect_and_auth
    socket2 = connect_and_auth

    socket1.write({ type: "resize", cols: 100, rows: 30 }.to_json)
    socket1.write("\n")
    Timeout.timeout(2) { sleep 0.01 until pty_in.winsize_calls.any? }
    expect(pty_in.winsize_calls.last).to eq([ 30, 100 ])

    socket2.write({ type: "resize", cols: 80, rows: 24 }.to_json)
    socket2.write("\n")
    Timeout.timeout(2) { sleep 0.01 until pty_in.winsize_calls.size >= 2 }
    expect(pty_in.winsize_calls.last).to eq([ 24, 80 ])

    socket1.close
    socket2.close
    thread.join(2)
  ensure
    socket1&.close unless socket1&.closed?
    socket2&.close unless socket2&.closed?
  end

  it "recomputes minimum terminal size when a client disconnects" do
    relay, child_output_write, _, pty_in = build_relay
    pty_alive = true
    allow(relay).to receive(:pty_alive?).with(pid) { pty_alive }
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket1 = connect_and_auth
    socket2 = connect_and_auth

    socket1.write({ type: "resize", cols: 80, rows: 24 }.to_json)
    socket1.write("\n")
    socket2.write({ type: "resize", cols: 100, rows: 30 }.to_json)
    socket2.write("\n")
    Timeout.timeout(2) { sleep 0.01 until pty_in.winsize_calls.size >= 2 }

    socket1.close
    Timeout.timeout(2) { sleep 0.01 until pty_in.winsize_calls.size >= 3 }
    expect(pty_in.winsize_calls.last).to eq([ 30, 100 ])

    child_output_write.write("after disconnect")
    frame = read_json_frame(socket2)
    expect(frame["type"]).to eq("output")
    expect(Base64.decode64(frame["data"])).to eq("after disconnect")

    pty_alive = false
    socket2.close
    thread.join(2)
    expect(session.reload).to be_finished
  ensure
    socket1&.close unless socket1&.closed?
    socket2&.close unless socket2&.closed?
    child_output_write&.close unless child_output_write&.closed?
  end

  it "waits for all clients to disconnect before applying the reconnect timeout" do
    stub_const("#{described_class}::RECONNECT_TIMEOUT", 0.1)
    relay, _, _, = build_relay
    allow(relay).to receive(:pty_alive?).with(pid).and_return(true)
    thread = run_relay(relay)
    thread[:terminal_relay_spec] = true
    socket1 = connect_and_auth
    socket2 = connect_and_auth

    socket1.close
    sleep 0.05
    expect(thread).to be_alive

    socket2.close
    thread.join(2)
    expect(thread).not_to be_alive
    expect(session.reload).to be_finished
    expect(session.outcome).to eq("exited")
  ensure
    socket1&.close unless socket1&.closed?
    socket2&.close unless socket2&.closed?
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
