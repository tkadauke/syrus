require "json"
require "io/console"
require "pty"
require "socket"
require "base64"

class TerminalRelay
  DEFAULT_RELAY_HOST = "127.0.0.1".freeze
  SELECT_TIMEOUT_SECONDS = 0.1
  RELAY_ADDRESS_TIMEOUT = 10
  RECONNECT_TIMEOUT = 120
  KILL_POLL_INTERVAL_SECONDS = 5
  READ_CHUNK_BYTES = 16 * 1024
  SCROLLBACK_SIZE = 256 * 1024

  class AuthenticationFailed < StandardError; end

  def initialize(session:, command:, env: {})
    @session = session
    @command = command
    @env = env
    @connections = []
    @connections_lock = Mutex.new
    @client_sizes = {}
    @scrollback = +""
    @scrollback_lock = Mutex.new
    @empty_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @stop = false
    @connection_threads = []
    @connection_threads_lock = Mutex.new
  end

  def relay_host
    ENV["SYRUS_TERMINAL_HOST"].presence || DEFAULT_RELAY_HOST
  end

  def run
    host = relay_host
    server = TCPServer.new(host, 0)
    port = server.addr[1]
    record_relay_address!(host, port)

    spawn_pty do |pty_out, pty_in, pid|
      pty_thread = Thread.new { broadcast_pty_output(pty_out) }

      begin
        accept_connections(server, pid, pty_in)
      ensure
        @stop = true
        close_all_connections
        conn_threads = @connection_threads_lock.synchronize { @connection_threads.dup }
        conn_threads.each { |t| t.join(2) }
        pty_thread.join
        close_io(pty_out)
        close_io(pty_in)
        terminate_pid(pid) if pid
        wait_pid(pid) if pid
      end
    end
  ensure
    close_io(server)
    finalize!
  end

  private

  def broadcast_pty_output(pty_out)
    until @stop
      next unless readable?(pty_out)

      data = begin
        pty_out.read_nonblock(READ_CHUNK_BYTES)
      rescue EOFError, Errno::EIO, IOError, SystemCallError
        @stop = true
        break
      end

      append_scrollback(data)
      broadcast(output_frame(data))
    end
  end

  def append_scrollback(data)
    @scrollback_lock.synchronize do
      @scrollback << data
      if @scrollback.bytesize > SCROLLBACK_SIZE
        excess = @scrollback.bytesize - SCROLLBACK_SIZE
        @scrollback = @scrollback.byteslice(excess, SCROLLBACK_SIZE) || +""
      end
    end
  end

  def broadcast(frame)
    @connections_lock.synchronize do
      @connections.delete_if do |conn|
        begin
          conn.write(frame)
          false
        rescue IOError, Errno::EPIPE, SystemCallError
          close_io(conn)
          true
        end
      end
    end
  end

  def accept_connections(server, pid, pty_in)
    ever_connected = false

    loop do
      break if @stop

      ready = IO.select([ server ], nil, nil, SELECT_TIMEOUT_SECONDS)

      unless ready
        break if @stop

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        idle_since, conn_count = @connections_lock.synchronize { [ @empty_since, @connections.size ] }

        if conn_count.zero?
          if ever_connected
            break unless pty_alive?(pid)
            break if (now - idle_since) >= RECONNECT_TIMEOUT
          else
            break if (now - idle_since) >= RELAY_ADDRESS_TIMEOUT
          end
        end

        next
      end

      conn = begin
        server.accept_nonblock
      rescue IO::WaitReadable, Errno::EAGAIN
        next
      end

      ever_connected = true
      t = Thread.new { handle_connection(conn, pid, pty_in) }
      @connection_threads_lock.synchronize { @connection_threads << t }
    end
  end

  def handle_connection(conn, pid, pty_in)
    return unless authenticate!(conn)

    # Hold the scrollback lock while joining @connections so no PTY chunk can
    # land in the scrollback after the snapshot but before we're in the
    # broadcast set (which would cause a gap in the client's output stream).
    snapshot = @scrollback_lock.synchronize do
      @connections_lock.synchronize { @connections << conn }
      @scrollback.dup
    end
    send_frame(conn, replay_frame(snapshot)) unless snapshot.empty?

    handle_connection_input(conn, pid, pty_in)
  ensure
    @connections_lock.synchronize do
      @connections.delete(conn)
      @client_sizes.delete(conn.object_id)
      @empty_since = Process.clock_gettime(Process::CLOCK_MONOTONIC) if @connections.empty?
    end
    recompute_winsize(pty_in)
    close_io(conn)
  end

  def handle_connection_input(conn, pid, pty_in)
    last_kill_poll = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    control_buffer = +""

    until @stop
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if now - last_kill_poll >= KILL_POLL_INTERVAL_SECONDS
        last_kill_poll = now
        if session_finished?
          terminate_pid(pid)
          break
        end
      end

      next unless readable?(conn)

      data = read_conn_data(conn)
      break unless data

      control_buffer = handle_conn_data(data, control_buffer, conn, pty_in)
    end
  rescue EOFError, Errno::EIO, IOError, SystemCallError
    nil
  end

  def recompute_winsize(pty_in)
    sizes = @connections_lock.synchronize { @client_sizes.values.dup }
    return if sizes.empty?

    min_cols = sizes.map(&:first).min
    min_rows = sizes.map(&:last).min
    pty_in.winsize = [ min_rows, min_cols ]
  rescue IOError, SystemCallError
    nil
  end

  def close_all_connections
    @connections_lock.synchronize do
      @connections.each { |conn| close_io(conn) }
      @connections.clear
    end
  end

  def send_frame(conn, frame)
    conn.write(frame)
  rescue IOError, Errno::EPIPE, SystemCallError
    nil
  end

  def output_frame(data)
    "#{JSON.generate(type: "output", data: Base64.strict_encode64(data))}\n"
  end

  def replay_frame(data)
    "#{JSON.generate(type: "replay", data: Base64.strict_encode64(data))}\n"
  end

  def spawn_pty(&block)
    PTY.spawn(@env, *@command, chdir: @session.working_directory, &block)
  end

  def authenticate!(conn)
    line = conn.gets
    raise AuthenticationFailed, "missing terminal relay auth frame" unless line

    payload = JSON.parse(line)
    token = payload["token"].to_s
    expected = @session.auth_token.to_s
    return true if token.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(token, expected)

    raise AuthenticationFailed, "invalid terminal relay auth token"
  rescue JSON::ParserError
    raise AuthenticationFailed, "invalid terminal relay auth frame"
  rescue AuthenticationFailed
    close_io(conn)
    false
  end

  def readable?(io)
    IO.select([ io ], nil, nil, SELECT_TIMEOUT_SECONDS)
  rescue IOError, SystemCallError
    false
  end

  def read_conn_data(conn)
    conn.read_nonblock(READ_CHUNK_BYTES)
  rescue EOFError, Errno::EIO, IOError, SystemCallError
    nil
  end

  def session_finished?
    with_connection do
      @session.reload.finished_at.present?
    end
  end

  def handle_conn_data(data, control_buffer, conn, pty_in)
    return +"" if data.empty?

    pending = control_buffer.empty? ? data : "#{control_buffer}#{data}"
    return pending if partial_control_frame?(pending)

    until pending.empty?
      unless pending.start_with?("{") && pending.include?("\n")
        pty_in.write(pending)
        return +""
      end

      newline_index = pending.index("\n")
      line = pending[0...newline_index]
      pending = pending[(newline_index + 1)..] || +""

      unless handle_control_frame("#{line}\n", conn, pty_in)
        pty_in.write("#{line}\n")
      end
    end

    +""
  end

  def partial_control_frame?(data)
    data.start_with?("{") && !data.include?("\n")
  end

  def handle_control_frame(frame, conn, pty_in)
    payload = JSON.parse(frame)

    case payload["type"]
    when "input"
      pty_in.write(payload["data"].to_s)
      true
    when "resize"
      cols = Integer(payload["cols"])
      rows = Integer(payload["rows"])
      if rows.positive? && cols.positive?
        @connections_lock.synchronize { @client_sizes[conn.object_id] = [ cols, rows ] }
        recompute_winsize(pty_in)
      end
      true
    else
      false
    end
  rescue JSON::ParserError, ArgumentError, TypeError
    false
  end

  def terminate_pid(pid)
    Process.kill("TERM", pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def wait_pid(pid)
    Process.wait(pid)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  def pty_alive?(pid)
    Process.waitpid(pid, Process::WNOHANG).nil?
  rescue Errno::ECHILD, Errno::ESRCH
    false
  end

  def close_io(io)
    return unless io

    io.close unless io.closed?
  rescue IOError, SystemCallError
    nil
  end

  def finalize!
    with_connection do
      TerminalSession.where(id: @session.id, finished_at: nil)
                     .update_all(finished_at: Time.current, outcome: "exited")
    end
  end

  def record_relay_address!(host, port)
    with_connection do
      @session.update!(relay_address: "#{host}:#{port}")
    end
  end

  def with_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end
end
