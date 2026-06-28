require "json"
require "pty"
require "socket"

class TerminalRelay
  POLL_INTERVAL = 5
  READ_SIZE = 4096

  def initialize(session:, command:, env:)
    @session = session
    @command = command
    @env = env
    @relay_host = ENV.fetch("SYRUS_TERMINAL_HOST", "127.0.0.1")
  end

  def run
    server = TCPServer.new(@relay_host, 0)
    port = server.addr[1]
    @session.update!(relay_address: "#{@relay_host}:#{port}")

    @connection = server.accept
    server.close
    server = nil

    return false unless authenticate_connection

    @pty_out, @pty_in, @pty_pid = PTY.spawn(@env, *@command, chdir: @session.working_directory)
    start_threads
    wait_for_threads
    true
  ensure
    close_io(@connection)
    close_io(@pty_out)
    close_io(@pty_in)
    close_io(server)
    terminate_pty
    wait_for_pty
    TerminalSession.where(id: @session.id, finished_at: nil)
      .update_all(finished_at: Time.current, outcome: "exited")
  end

  private

  def authenticate_connection
    line = @connection.gets
    payload = JSON.parse(line || "{}")
    token = payload["token"].to_s

    return false unless token.bytesize == @session.auth_token.bytesize

    ActiveSupport::SecurityUtils.secure_compare(token, @session.auth_token)
  rescue JSON::ParserError
    false
  end

  def start_threads
    @pty_thread = Thread.new { relay_pty_output }
    @conn_thread = Thread.new { relay_connection_input }
  end

  def wait_for_threads
    loop do
      break unless @pty_thread&.alive? && @conn_thread&.alive?

      sleep 0.1
    end
  end

  def relay_pty_output
    loop do
      @connection.write(@pty_out.readpartial(READ_SIZE))
    end
  rescue EOFError, Errno::EIO, IOError, SystemCallError
    nil
  end

  def relay_connection_input
    loop do
      terminate_pty if @session.reload.finished_at

      readable = IO.select([ @connection ], nil, nil, POLL_INTERVAL)
      next unless readable

      line = @connection.gets
      break if line.nil?

      handle_frame(JSON.parse(line))
    end
  rescue EOFError, Errno::EIO, IOError, JSON::ParserError, SystemCallError
    nil
  end

  def handle_frame(frame)
    case frame["type"]
    when "input"
      @pty_in.write(frame["data"].to_s)
    when "resize"
      rows = frame["rows"].to_i
      cols = frame["cols"].to_i
      @pty_in.winsize = [ rows, cols ] if rows.positive? && cols.positive?
    end
  end

  def terminate_pty
    return unless @pty_pid

    Process.kill("TERM", @pty_pid)
  rescue Errno::ESRCH
    nil
  end

  def wait_for_pty
    return unless @pty_pid

    Process.wait(@pty_pid)
  rescue Errno::ECHILD
    nil
  end

  def close_io(io)
    io&.close unless io&.closed?
  rescue IOError, SystemCallError
    nil
  end
end
