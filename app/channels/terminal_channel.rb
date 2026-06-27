require "base64"
require "socket"

class TerminalChannel < ApplicationCable::Channel
  RELAY_ADDRESS_TIMEOUT = 10.seconds
  RELAY_ADDRESS_POLL_INTERVAL = 0.2.seconds
  RELAY_READ_SIZE = 4096
  RELAY_SELECT_TIMEOUT = 0.05

  def subscribed
    @session = TerminalSession.running.find_by(id: params[:session_id])

    return reject unless Feature.terminal_enabled?
    return reject unless @session&.user_id == current_user.id
    return reject unless wait_for_relay_address

    connect_to_relay
    stream_from_relay
  rescue Errno::ECONNREFUSED, SocketError, IOError, SystemCallError
    cleanup_relay
    reject
  end

  def unsubscribed
    cleanup_relay
  end

  def receive(data)
    @relay_socket&.write("#{data.except("action").to_json}\n")
  rescue IOError, Errno::EPIPE
    transmit({ type: "disconnected" })
  end

  private

  def wait_for_relay_address
    deadline = Time.current + RELAY_ADDRESS_TIMEOUT

    until @session.relay_ready? || Time.current > deadline
      sleep RELAY_ADDRESS_POLL_INTERVAL
      @session.reload
    end

    @session.relay_ready?
  end

  def connect_to_relay
    host, port = @session.relay_address.split(":", 2)

    @relay_socket = TCPSocket.new(host, port.to_i)
    @relay_socket.puts({ token: @session.auth_token }.to_json)
  end

  def stream_from_relay
    @relay_thread = Thread.new do
      loop do
        chunk = @relay_socket.read_nonblock(RELAY_READ_SIZE)
        transmit({ type: "output", data: Base64.strict_encode64(chunk) })
      rescue IO::WaitReadable
        IO.select([ @relay_socket ], nil, nil, RELAY_SELECT_TIMEOUT)
        retry
      rescue EOFError, IOError, Errno::ECONNRESET
        transmit({ type: "disconnected" })
        break
      end
    end
  end

  def cleanup_relay
    @relay_socket&.close
  rescue IOError
    nil
  ensure
    @relay_thread&.kill
  end
end
