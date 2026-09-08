require "base64"
require "json"
require "socket"

class RuntimeTerminalFakeRelay
  attr_reader :auth_payload

  def initialize(replay: "")
    @server = TCPServer.new("127.0.0.1", 0)
    @replay = replay
    @controls = Queue.new
    @client_ready = Queue.new
    @thread = Thread.new { run }
  end

  def address
    "127.0.0.1:#{@server.addr[1]}"
  end

  def write_output(data)
    client = @client_ready.pop
    @client_ready << client
    client.write(frame("output", data))
  end

  def next_control(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return @controls.pop(true)
    rescue ThreadError
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def stop
    @client&.close
    @server.close
    @thread.join(1)
  rescue IOError, SystemCallError
    nil
  end

  private

  def run
    @client = @server.accept
    @auth_payload = JSON.parse(@client.gets)
    @client.write(frame("replay", @replay)) if @replay.present?
    @client_ready << @client

    while (line = @client.gets)
      @controls << JSON.parse(line)
    end
  rescue IOError, SystemCallError, JSON::ParserError
    nil
  end

  def frame(type, data)
    "#{JSON.generate(type: type, data: Base64.strict_encode64(data))}\n"
  end
end
