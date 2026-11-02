require "base64"
require "json"
require "socket"

module RuntimeTerminal
  class RelayClient
    READ_CHUNK_BYTES = 4096
    DRAIN_TIMEOUT_SECONDS = 0.05
    INITIAL_REPLAY_TIMEOUT_SECONDS = 0.1
    MAX_SCROLLBACK_BYTES = 1_048_576
    MAX_READ_BUFFER_BYTES = 1_048_576
    MAX_COLS = Screen::MAX_COLS
    MAX_ROWS = Screen::MAX_ROWS
    MAX_WAIT_SECONDS = 30.0

    NAMED_KEY_SEQUENCES = {
      "Enter" => "\r", "Return" => "\r", "Tab" => "\t", "Shift+Tab" => "\e[Z",
      "Backspace" => "\x7f", "Escape" => "\e", "Esc" => "\e",
      "ArrowUp" => "\e[A", "ArrowDown" => "\e[B", "ArrowRight" => "\e[C", "ArrowLeft" => "\e[D",
      "Delete" => "\e[3~", "Insert" => "\e[2~", "Home" => "\e[H", "End" => "\e[F",
      "PageUp" => "\e[5~", "PageDown" => "\e[6~",
      "F1" => "\eOP", "F2" => "\eOQ", "F3" => "\eOR", "F4" => "\eOS",
      "F5" => "\e[15~", "F6" => "\e[17~", "F7" => "\e[18~", "F8" => "\e[19~",
      "F9" => "\e[20~", "F10" => "\e[21~", "F11" => "\e[23~", "F12" => "\e[24~"
    }.freeze

    class ConnectionError < StandardError; end
    class UnsupportedInput < StandardError; end

    def initialize(terminal_session, generation: 0, initial_dimensions: nil)
      @terminal_session = terminal_session
      @socket = connect_socket(terminal_session)
      @read_buffer = +""
      @scrollback = +""
      @screen = Screen.new(generation: generation)
      @closed = false
      @lock = Mutex.new

      authenticate!
      drain(timeout: INITIAL_REPLAY_TIMEOUT_SECONDS)
      input(type: "resize", **initial_dimensions) if initial_dimensions
    end

    def inspect_scrollback
      @lock.synchronize do
        screen_locked!
        drain_locked
        @scrollback.dup
      end
    end

    def inspect_screen(after_generation: nil, wait_for_change: false, wait_for_text: nil, quiet_seconds: 0, timeout_seconds: 0, include_styles: false)
      timeout_seconds = bounded_wait_seconds(timeout_seconds)
      deadline = monotonic_now + timeout_seconds
      snapshot = @lock.synchronize do
        screen_locked!
        drain_locked
        baseline = after_generation.nil? && wait_for_change ? @screen.generation : after_generation
        @screen.snapshot.then { |current| [ current, baseline ] }
      end
      snapshot, baseline = snapshot
      settled, snapshot = wait_for_screen(
        after_generation: baseline,
        wait_for_text: wait_for_text,
        quiet_seconds: quiet_seconds,
        deadline: deadline,
        initial_snapshot: snapshot
      )
      screen_payload(snapshot, include_styles: include_styles).merge(settled: settled)
    end

    # Snapshot and semantic inspection intentionally read the same Screen
    # instance while holding the same lock. This keeps captured evidence from
    # drifting from what runtime_inspect reports to the agent.
    def capture_screen
      @lock.synchronize do
        screen_locked!
        drain_locked
        @screen.snapshot
      end
    end

    def closed?
      @lock.synchronize { @closed || @socket&.closed? }
    end

    def screen_generation
      @lock.synchronize { @screen&.generation || @last_screen_generation.to_i }
    end

    def input(event)
      @lock.synchronize do
        screen_locked!
        frames = frames_for(event)
        frames.each { |frame| write_frame_locked(frame) }
        resize = frames.find { |frame| frame[:type] == "resize" }
        @screen.resize(resize.fetch(:cols), resize.fetch(:rows)) if resize
      end
      true
    end

    def close
      @lock.synchronize do
        @last_screen_generation = @screen&.generation.to_i
        @closed = true
        @socket&.close unless @socket&.closed?
        @screen = nil
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

    def wait_for_screen(after_generation:, wait_for_text:, quiet_seconds:, deadline:, initial_snapshot:)
      quiet_seconds = [[ Float(quiet_seconds), 0 ].max, [ deadline - monotonic_now, 0 ].max ].min
      settled_at = nil
      settled_generation = nil
      snapshot = initial_snapshot

      loop do
        generation_ready = after_generation.nil? || snapshot.fetch(:generation) > Integer(after_generation)
        text_ready = wait_for_text.blank? || snapshot.fetch(:lines).any? { |line| line.fetch(:text).include?(wait_for_text.to_s) }

        if generation_ready && text_ready
          if settled_generation != snapshot.fetch(:generation)
            settled_generation = snapshot.fetch(:generation)
            settled_at = monotonic_now
          end
          return [ true, snapshot ] if monotonic_now - settled_at >= quiet_seconds
        else
          settled_at = nil
          settled_generation = nil
        end

        break if monotonic_now >= deadline
        snapshot = drain_screen_until(deadline) || snapshot
      end
      [ false, snapshot ]
    end

    def drain_screen_until(deadline)
      loop do
        if @lock.try_lock
          snapshot = nil
          begin
            screen_locked!
            drain_locked(timeout: [ DRAIN_TIMEOUT_SECONDS, [ deadline - monotonic_now, 0 ].max ].min)
            snapshot = @screen.snapshot
          ensure
            @lock.unlock
          end
          Thread.pass
          return snapshot
        end
        return nil if monotonic_now >= deadline

        Thread.pass
      end
    end

    def bounded_wait_seconds(seconds)
      [[ Float(seconds), 0 ].max, MAX_WAIT_SECONDS].min
    end

    def screen_payload(snapshot, include_styles:)
      payload = {
        kind: "terminal_screen",
        generation: snapshot.fetch(:generation),
        cols: snapshot.fetch(:cols),
        rows: snapshot.fetch(:rows),
        alternate: snapshot.fetch(:alternate),
        cursor: snapshot.fetch(:cursor),
        lines: snapshot.fetch(:lines).map { |line| line.fetch(:text) }
      }
      payload[:styled_runs] = snapshot.fetch(:lines).map { |line| compact_runs(line.fetch(:cells)) } if include_styles
      payload
    end

    def compact_runs(cells)
      visible_cells = cells.dup
      visible_cells.pop while visible_cells.last&.fetch(:text) == " " && visible_cells.last&.fetch(:width) == 1
      visible_cells.each_with_object([]) do |cell, runs|
        next if cell.fetch(:width).zero?

        attributes = cell.slice(:foreground, :background, :styles)
        if runs.last&.slice(:foreground, :background, :styles) == attributes
          runs.last[:text] << cell.fetch(:text)
        else
          runs << attributes.merge(text: cell.fetch(:text))
        end
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def append_frames(chunk)
      @read_buffer << chunk
      @read_buffer = @read_buffer.byteslice(-MAX_READ_BUFFER_BYTES, MAX_READ_BUFFER_BYTES) if @read_buffer.bytesize > MAX_READ_BUFFER_BYTES

      while (idx = @read_buffer.index("\n"))
        line = @read_buffer.slice!(0, idx + 1).chomp
        next if line.empty?

        append_frame(line)
      end
    end

    def append_frame(line)
      payload = JSON.parse(line)
      return unless %w[replay output].include?(payload["type"])

      decoded = Base64.decode64(payload["data"].to_s)
      @scrollback << decoded
      trim_scrollback
      @screen.apply(decoded)
    rescue JSON::ParserError, ArgumentError
      nil
    end

    def write_frame_locked(frame)
      @socket.write("#{JSON.generate(frame)}\n")
    rescue IOError, Errno::EPIPE, SystemCallError => e
      @closed = true
      raise ConnectionError, e.message
    end

    def trim_scrollback
      return unless @scrollback.bytesize > MAX_SCROLLBACK_BYTES

      @scrollback = @scrollback.byteslice(-MAX_SCROLLBACK_BYTES, MAX_SCROLLBACK_BYTES)
        .dup.force_encoding(Encoding::UTF_8).scrub
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
      if cols > MAX_COLS || rows > MAX_ROWS
        raise UnsupportedInput, "resize exceeds maximum #{MAX_COLS}x#{MAX_ROWS}"
      end

      { type: "resize", cols: cols, rows: rows }
    rescue KeyError, ArgumentError, TypeError
      raise UnsupportedInput, "resize requires positive cols and rows"
    end

    def screen_locked!
      raise ConnectionError, "terminal relay connection is closed" if @closed || @screen.nil?

      @screen
    end

    def keyboard_sequence(event)
      text = event["data"] || event["text"]
      return text.to_s if text.present?

      key = event["key"].to_s
      modifiers = Array(event["modifiers"]).map { |modifier| modifier.to_s.downcase }
      modifiers << "ctrl" if ActiveModel::Type::Boolean.new.cast(event["ctrl"] || event["control"])
      modifiers << "shift" if ActiveModel::Type::Boolean.new.cast(event["shift"])
      chord = key.split("+")
      key = chord.pop.to_s
      modifiers.concat(chord.map(&:downcase))

      return NAMED_KEY_SEQUENCES.fetch("Shift+Tab") if key == "Tab" && modifiers.include?("shift")
      return control_sequence(key) if modifiers.intersect?(%w[ctrl control])

      NAMED_KEY_SEQUENCES.fetch(key) do
        raise UnsupportedInput, "keyboard event requires text/data or a supported key or chord"
      end
    end

    def control_sequence(key)
      character = key.length == 1 ? key.upcase : nil
      codepoint = character&.ord
      return (codepoint - 64).chr if codepoint&.between?(64, 95)
      return "\x00" if key == "Space"
      return "\x7f" if key == "?"

      raise UnsupportedInput, "unsupported Ctrl combination Ctrl+#{key}"
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
