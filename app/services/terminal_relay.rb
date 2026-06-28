require "json"
require "io/console"
require "pty"
require "socket"

class TerminalRelay
  DEFAULT_RELAY_HOST = "127.0.0.1".freeze
  SELECT_TIMEOUT_SECONDS = 0.1
  RELAY_ADDRESS_TIMEOUT = 10
  RECONNECT_TIMEOUT = 120
  KILL_POLL_INTERVAL_SECONDS = 5
  READ_CHUNK_BYTES = 16 * 1024

  class AuthenticationFailed < StandardError; end

  def initialize(session:, command:, env: {})
    @session = session
    @command = command
    @env = env
  end

  def relay_host
    ENV["SYRUS_TERMINAL_HOST"].presence || DEFAULT_RELAY_HOST
  end

  def run
    host = relay_host
    server = TCPServer.new(host, 0)
    port = server.addr[1]
    @session.update!(relay_address: "#{host}:#{port}")

    spawn_pty do |pty_out, pty_in, pid|
      conn = nil
      first_connection = true

      loop do
        timeout = first_connection ? RELAY_ADDRESS_TIMEOUT : RECONNECT_TIMEOUT
        break unless wait_for_connection(server, timeout, pid)

        conn = server.accept_nonblock
        first_connection = false

        break unless authenticate!(conn)

        relay(pty_out, pty_in, conn, pid)
        close_io(conn)
        conn = nil

        break if session_finished?
        break unless pty_alive?(pid)
      end
    ensure
      close_io(conn)
      close_io(pty_out)
      close_io(pty_in)
      terminate_pid(pid) if pid
      wait_pid(pid) if pid
    end
  ensure
    close_io(server)
    finalize!
  end

  private

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

  def relay(pty_out, pty_in, conn, pid)
    stop = false
    stop_lock = Mutex.new
    stop_relay = lambda do |close_pty: false|
      stop_lock.synchronize do
        unless stop
          stop = true
          close_io(conn)
          if close_pty
            close_io(pty_out)
            close_io(pty_in)
          end
        end
      end
    end

    pty_thread = Thread.new do
      begin
        until stop
          next unless readable?(pty_out)

          data = pty_out.read_nonblock(READ_CHUNK_BYTES)
          conn.write(data)
        end
      rescue EOFError, Errno::EIO, IOError, SystemCallError
        stop_relay.call(close_pty: true)
      end
    end

    conn_thread = Thread.new do
      control_buffer = +""
      last_kill_poll = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        until stop
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if now - last_kill_poll >= KILL_POLL_INTERVAL_SECONDS
            last_kill_poll = now
            if @session.reload.finished_at.present?
              terminate_pid(pid)
              stop_relay.call(close_pty: true)
              next
            end
          end

          next unless readable?(conn)

          data = read_conn_data(conn)
          unless data
            stop_relay.call(close_pty: false)
            next
          end

          control_buffer = handle_conn_data(data, control_buffer, pty_in)
        end
      rescue IOError, SystemCallError
        stop_relay.call(close_pty: true)
      end
    end

    [ pty_thread, conn_thread ].each(&:join)
  ensure
    close_io(conn)
  end

  def wait_for_connection(server, timeout, pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return false unless remaining.positive?

      return true if IO.select([ server ], nil, nil, [ SELECT_TIMEOUT_SECONDS, remaining ].min)
      return false unless pty_alive?(pid)
    end
  rescue IOError, SystemCallError
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
    @session.reload.finished_at.present?
  end

  def handle_conn_data(data, control_buffer, pty_in)
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

      unless handle_control_frame("#{line}\n", pty_in)
        pty_in.write("#{line}\n")
      end
    end

    +""
  end

  def partial_control_frame?(data)
    data.start_with?("{") && !data.include?("\n")
  end

  def handle_control_frame(frame, pty_in)
    payload = JSON.parse(frame)

    case payload["type"]
    when "input"
      pty_in.write(payload["data"].to_s)
      true
    when "resize"
      cols = Integer(payload["cols"])
      rows = Integer(payload["rows"])
      pty_in.winsize = [ rows, cols ] if rows.positive? && cols.positive?
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
    TerminalSession.where(id: @session.id, finished_at: nil)
                   .update_all(finished_at: Time.current, outcome: "exited")
  end
end
