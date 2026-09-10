require "base64"
require "json"
require "socket"

module RuntimeTerminal
  class RelayClient
    READ_CHUNK_BYTES = 4096
    DRAIN_TIMEOUT_SECONDS = 0.05
    INITIAL_REPLAY_TIMEOUT_SECONDS = 0.1

    class ConnectionError < StandardError; end
    class UnsupportedInput < StandardError; end

    def initialize(terminal_session)
      @terminal_session = terminal_session
      @socket = connect_socket(terminal_session)
      @read_buffer = +""
      @scrollback = +""
      @closed = false
      @lock = Mutex.new

      authenticate!
      drain(timeout: INITIAL_REPLAY_TIMEOUT_SECONDS)
    end

    def inspect_scrollback
      @lock.synchronize do
        drain_locked
        @scrollback.dup
      end
    end

    def closed?
      @lock.synchronize { @closed || @socket&.closed? }
    end

    def input(event)
      frames_for(event).each { |frame| write_frame(frame) }
      true
    end

    def close
      @lock.synchronize do
        @closed = true
        @socket&.close unless @socket&.closed?
      rescue IOError, SystemCallError
        nil
      end
    end

    private

    def connect_socket(terminal_session)
      raise ConnectionError, "terminal relay is not ready" unless terminal_session.relay_ready?

      host, port = terminal_session.relay_address.to_s.split(":", 2)
      raise ConnectionError, "terminal relay address is invalid" if host.blank? || port.blank?

      TCPSocket.new(host, Integer(port))
    rescue ArgumentError, SocketError, SystemCallError => e
      raise ConnectionError, e.message
    end

    def authenticate!
      @socket.write("#{JSON.generate(token: @terminal_session.auth_token)}\n")
    end

    def drain(timeout:)
      @lock.synchronize { drain_locked(timeout: timeout) }
    end

    def drain_locked(timeout: DRAIN_TIMEOUT_SECONDS)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining.negative?

        ready = IO.select([ @socket ], nil, nil, remaining)
        break unless ready

        chunk = @socket.read_nonblock(READ_CHUNK_BYTES)
        append_frames(chunk)
      rescue IO::WaitReadable
        next
      rescue EOFError, IOError, SystemCallError
        @closed = true
        break
      end
    end

    def append_frames(chunk)
      @read_buffer << chunk

      while (idx = @read_buffer.index("\n"))
        line = @read_buffer.slice!(0, idx + 1).chomp
        next if line.empty?

        append_frame(line)
      end
    end

    def append_frame(line)
      payload = JSON.parse(line)
      return unless %w[replay output].include?(payload["type"])

      @scrollback << Base64.decode64(payload["data"].to_s)
    rescue JSON::ParserError, ArgumentError
      nil
    end

    def write_frame(frame)
      @lock.synchronize do
        raise ConnectionError, "terminal relay connection is closed" if @closed

        @socket.write("#{JSON.generate(frame)}\n")
      rescue IOError, Errno::EPIPE, SystemCallError => e
        @closed = true
        raise ConnectionError, e.message
      end
    end

    def frames_for(raw_event)
      event = raw_event.to_h.stringify_keys

      case event["type"].to_s
      when "stdin"
        [ input_frame(event.fetch("data", event["text"]).to_s) ]
      when "keyboard", "key"
        [ input_frame(keyboard_sequence(event)) ]
      when "resize"
        [ resize_frame(event) ]
      when "pointer", "mouse", "click", "mousedown", "mouseup", "mousemove", "wheel"
        pointer_frames(event)
      else
        raise UnsupportedInput, "unsupported terminal input event type #{event['type'].inspect}"
      end
    end

    def input_frame(data)
      { type: "input", data: data }
    end

    def resize_frame(event)
      cols = Integer(event.fetch("cols", event["columns"]))
      rows = Integer(event["rows"])
      raise UnsupportedInput, "resize requires positive cols and rows" unless cols.positive? && rows.positive?

      { type: "resize", cols: cols, rows: rows }
    rescue KeyError, ArgumentError, TypeError
      raise UnsupportedInput, "resize requires positive cols and rows"
    end

    def keyboard_sequence(event)
      text = event["data"] || event["text"]
      return text.to_s if text.present?

      key = event["key"].to_s
      {
        "Enter" => "\r",
        "Return" => "\r",
        "Tab" => "\t",
        "Backspace" => "\x7f",
        "Escape" => "\e",
        "ArrowUp" => "\e[A",
        "ArrowDown" => "\e[B",
        "ArrowRight" => "\e[C",
        "ArrowLeft" => "\e[D",
        "Delete" => "\e[3~",
        "Home" => "\e[H",
        "End" => "\e[F",
        "PageUp" => "\e[5~",
        "PageDown" => "\e[6~"
      }.fetch(key) do
        raise UnsupportedInput, "keyboard event requires text/data or a supported key"
      end
    end

    def pointer_frames(event)
      action = event.fetch("action", event["type"]).to_s
      return [ input_frame(mouse_sequence(event, button_code(event, default: 64), "M")) ] if action == "wheel_up"
      return [ input_frame(mouse_sequence(event, button_code(event, default: 65), "M")) ] if action == "wheel_down"

      case action
      when "click"
        [ input_frame(mouse_sequence(event, button_code(event), "M")), input_frame(mouse_sequence(event, 3, "m")) ]
      when "mousedown", "down", "press", "pointerdown"
        [ input_frame(mouse_sequence(event, button_code(event), "M")) ]
      when "mouseup", "up", "release", "pointerup"
        [ input_frame(mouse_sequence(event, 3, "m")) ]
      when "mousemove", "move", "pointermove"
        [ input_frame(mouse_sequence(event, button_code(event) + 32, "M")) ]
      when "wheel"
        direction = event["direction"].to_s
        code = direction == "down" || event["delta_y"].to_i.positive? ? 65 : 64
        [ input_frame(mouse_sequence(event, code, "M")) ]
      else
        raise UnsupportedInput, "unsupported terminal pointer action #{action.inspect}"
      end
    end

    def mouse_sequence(event, code, suffix)
      x = Integer(event["x"] || event["col"] || event["column"])
      y = Integer(event["y"] || event["row"])
      unless x.positive? && y.positive?
        raise UnsupportedInput, "pointer events require positive x/y terminal coordinates"
      end

      "\e[<#{code};#{x};#{y}#{suffix}"
    rescue KeyError, ArgumentError, TypeError
      raise UnsupportedInput, "pointer events require positive x/y terminal coordinates"
    end

    def button_code(event, default: nil)
      button = event.fetch("button", default || "left")
      return button if button.is_a?(Integer)

      {
        "left" => 0,
        "middle" => 1,
        "right" => 2,
        "none" => 0,
        "wheel_up" => 64,
        "wheel_down" => 65
      }.fetch(button.to_s) { raise UnsupportedInput, "unsupported terminal mouse button #{button.inspect}" }
    end
  end
end
