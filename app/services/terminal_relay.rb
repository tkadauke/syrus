require "json"
require "io/console"
require "pty"
require "socket"

class TerminalRelay
  SELECT_TIMEOUT_SECONDS = 0.1
  KILL_POLL_INTERVAL_SECONDS = 5
  READ_CHUNK_BYTES = 16 * 1024

  class AuthenticationFailed < StandardError; end

  def initialize(session:, command:, env: {})
    @session = session
    @command = command
    @env = env
  end

  def run
    server = TCPServer.new(relay_host, 0)
    port = server.addr[1]
    @session.update!(relay_address: "#{relay_host}:#{port}")

    spawn_pty do |pty_out, pty_in, pid|
      conn = server.accept
      server.close
      server = nil

      relay(pty_out, pty_in, conn, pid) if authenticate!(conn)
    ensure
      close_io(conn)
      terminate_pid(pid) if pid
      wait_pid(pid) if pid
    end
  ensure
    close_io(server)
    finalize!
  end

  private

  def relay_host
    ENV.fetch("SYRUS_TERMINAL_HOST", "127.0.0.1")
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

  def relay(pty_out, pty_in, conn, pid)
    stop = false
    stop_relay = -> { stop = true }

    pty_thread = Thread.new do
      begin
        until stop
          next unless readable?(pty_out)

          data = pty_out.read_nonblock(READ_CHUNK_BYTES)
          conn.write(data)
        end
      rescue EOFError, Errno::EIO, IOError, SystemCallError
        stop_relay.call
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
              stop_relay.call
              next
            end
          end

          next unless readable?(conn)

          data = conn.read_nonblock(READ_CHUNK_BYTES)
          control_buffer = handle_conn_data(data, control_buffer, pty_in)
        end
      rescue EOFError, Errno::EIO, IOError, SystemCallError
        stop_relay.call
      end
    end

    [ pty_thread, conn_thread ].each(&:join)
  ensure
    close_io(pty_out)
    close_io(pty_in)
    close_io(conn)
  end

  def readable?(io)
    IO.select([ io ], nil, nil, SELECT_TIMEOUT_SECONDS)
  rescue IOError, SystemCallError
    false
  end

  def handle_conn_data(data, control_buffer, pty_in)
    return +"" if data.empty?

    pending = control_buffer.empty? ? data : "#{control_buffer}#{data}"
    return pending if partial_resize_frame?(pending)

    if pending.start_with?("{") && pending.include?("\n")
      line, rest = pending.split("\n", 2)
      if handle_control_frame("#{line}\n", pty_in)
        pty_in.write(rest) if rest.present?
        return +""
      end
    end

    pty_in.write(pending)
    +""
  end

  def partial_resize_frame?(data)
    data.start_with?('{"type":"resize"') && !data.include?("\n")
  end

  def handle_control_frame(frame, pty_in)
    payload = JSON.parse(frame)
    return false unless payload["type"] == "resize"

    cols = Integer(payload["cols"])
    rows = Integer(payload["rows"])
    return true unless rows.positive? && cols.positive?

    pty_in.winsize = [ rows, cols ]
    true
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
