require "unicode/display_width"

module RuntimeTerminal
  # A bounded VT/ECMA-48 screen fed by the relay's gap-free replay/output stream.
  # It intentionally owns presentation state only; Terminal::Relay remains the
  # sole PTY owner and transport.
  class Screen
    DEFAULT_COLS = 80
    DEFAULT_ROWS = 24
    MAX_SCROLLBACK_ROWS = 1_000

    Cell = Data.define(:text, :width, :foreground, :background, :styles) do
      def as_json(*)
        { text: text, width: width, foreground: foreground, background: background, styles: styles }
      end
    end

    attr_reader :cols, :rows, :generation

    def initialize(cols: DEFAULT_COLS, rows: DEFAULT_ROWS, scrollback_limit: MAX_SCROLLBACK_ROWS, generation: 0)
      @scrollback_limit = scrollback_limit
      @generation = generation
      @utf8_pending = +"".b
      @parser_pending = +""
      @saved_cursor = {}
      resize(cols, rows, increment: false)
      reset_attributes
    end

    def apply(bytes)
      @generation += 1
      parse(decode(bytes))
      self
    end

    def resize(cols, rows, increment: true)
      cols = Integer(cols)
      rows = Integer(rows)
      raise ArgumentError, "terminal dimensions must be positive" unless cols.positive? && rows.positive?

      @generation += 1 if increment
      @cols = cols
      @rows = rows
      @primary ||= new_buffer
      @alternate ||= new_buffer
      [ @primary, @alternate ].each { |buffer| resize_buffer(buffer) }
      clamp_cursor
      self
    end

    def snapshot
      buffer = active_buffer
      {
        kind: "terminal_screen",
        generation: generation,
        cols: cols,
        rows: rows,
        alternate: @alternate_active,
        cursor: { row: @cursor_row, col: @cursor_col, visible: @cursor_visible },
        lines: buffer[:lines].map { |line| serialized_line(line) },
        scrollback: buffer[:scrollback].map { |line| serialized_line(line) }
      }
    end

    private

    def new_buffer
      { lines: Array.new(@rows) { blank_line }, scrollback: [] }
    end

    def blank_cell
      Cell.new(" ", 1, nil, nil, [].freeze)
    end

    def blank_line
      Array.new(@cols) { blank_cell }
    end

    def resize_buffer(buffer)
      buffer[:lines].each do |line|
        line.slice!(@cols..) if line.length > @cols
        line.concat(Array.new(@cols - line.length) { blank_cell }) if line.length < @cols
      end
      while buffer[:lines].length > @rows
        buffer[:scrollback] << buffer[:lines].shift
      end
      buffer[:lines].unshift(blank_line) while buffer[:lines].length < @rows
      trim_scrollback(buffer)
    end

    def decode(bytes)
      @utf8_pending << bytes.to_s.b
      decoded = @utf8_pending.dup.force_encoding(Encoding::UTF_8)
      if decoded.valid_encoding?
        @utf8_pending.clear
        return decoded
      end

      valid_end = @utf8_pending.length
      valid_end -= 1 while valid_end.positive? && !@utf8_pending.byteslice(0, valid_end).dup.force_encoding(Encoding::UTF_8).valid_encoding?
      return "" if valid_end.zero?

      prefix = @utf8_pending.slice!(0, valid_end)
      prefix.force_encoding(Encoding::UTF_8).scrub
    end

    def parse(text)
      data = @parser_pending << text
      @parser_pending = +""
      index = 0
      while index < data.length
        char = data[index]
        if char == "\e"
          consumed = parse_escape(data, index)
          unless consumed
            @parser_pending = data[index..]
            break
          end
          index += consumed
        else
          consume_character(char)
          index += 1
        end
      end
    end

    def parse_escape(data, index)
      return nil unless data[index + 1]
      case data[index + 1]
      when "["
        match = /\A\e\[([?=>!]?[0-9:;<=>?]*[ -\/]*)?([@-~])/.match(data[index..])
        return nil unless match
        apply_csi(match[1].to_s, match[2])
        match[0].length
      when "]"
        tail = data[index + 2..]
        ending = tail.index("\a")
        ending ||= tail.index("\e\\")
        return nil unless ending
        index + 2 + ending + (tail[ending, 2] == "\e\\" ? 2 : 1) - index
      when "7"
        save_cursor
        2
      when "8"
        restore_cursor
        2
      when "D"
        line_feed
        2
      when "M"
        reverse_index
        2
      when "c"
        reset
        2
      else
        2
      end
    end

    def consume_character(char)
      case char
      when "\n", "\v", "\f" then line_feed
      when "\r" then @cursor_col = 0
      when "\b" then @cursor_col = [ @cursor_col - 1, 0 ].max
      when "\t" then @cursor_col = [ ((@cursor_col / 8) + 1) * 8, cols - 1 ].min
      else
        return if char.ord < 32 || char.ord == 127
        put_character(char)
      end
    end

    def put_character(char)
      width = Unicode::DisplayWidth.of(char, ambiguous: 1)
      if width.zero?
        col = [ @cursor_col - 1, 0 ].max
        cell = active_buffer[:lines][@cursor_row][col]
        active_buffer[:lines][@cursor_row][col] = cell.with(text: "#{cell.text}#{char}")
        return
      end
      line_feed if @cursor_col >= cols
      width = 1 if width > cols
      line_feed if width == 2 && @cursor_col == cols - 1
      line = active_buffer[:lines][@cursor_row]
      line[@cursor_col] = styled_cell(char, width)
      line[@cursor_col + 1] = Cell.new("", 0, @foreground, @background, @styles.dup.freeze) if width == 2
      @cursor_col += width
    end

    def styled_cell(text, width)
      Cell.new(text, width, @foreground, @background, @styles.dup.freeze)
    end

    def apply_csi(raw, final)
      private_mode = raw.start_with?("?")
      values = raw.sub(/\A[?=>!]/, "").split(";", -1).map { |value| value.empty? ? nil : value.to_i }
      first = values[0] || 0
      case final
      when "A" then @cursor_row = [ @cursor_row - nonzero(first), 0 ].max
      when "B" then @cursor_row = [ @cursor_row + nonzero(first), rows - 1 ].min
      when "C" then @cursor_col = [ @cursor_col + nonzero(first), cols - 1 ].min
      when "D" then @cursor_col = [ @cursor_col - nonzero(first), 0 ].max
      when "E" then @cursor_row = [ @cursor_row + nonzero(first), rows - 1 ].min; @cursor_col = 0
      when "F" then @cursor_row = [ @cursor_row - nonzero(first), 0 ].max; @cursor_col = 0
      when "G", "`" then @cursor_col = [[ nonzero(first) - 1, 0 ].max, cols - 1].min
      when "H", "f" then position(values)
      when "J" then erase_display(first)
      when "K" then erase_line(first)
      when "m" then apply_sgr(values)
      when "s" then save_cursor
      when "u" then restore_cursor
      when "h" then set_mode(values, true) if private_mode
      when "l" then set_mode(values, false) if private_mode
      when "L" then insert_lines(nonzero(first))
      when "M" then delete_lines(nonzero(first))
      when "P" then delete_characters(nonzero(first))
      when "@" then insert_characters(nonzero(first))
      end
    end

    def nonzero(value) = value.to_i.zero? ? 1 : value.to_i

    def position(values)
      @cursor_row = [[ nonzero(values[0]) - 1, 0 ].max, rows - 1].min
      @cursor_col = [[ nonzero(values[1]) - 1, 0 ].max, cols - 1].min
    end

    def line_feed
      if @cursor_row == rows - 1
        buffer = active_buffer
        removed = buffer[:lines].shift
        buffer[:scrollback] << removed unless @alternate_active
        trim_scrollback(buffer)
        buffer[:lines] << blank_line
      else
        @cursor_row += 1
      end
    end

    def reverse_index
      if @cursor_row.zero?
        active_buffer[:lines].pop
        active_buffer[:lines].unshift(blank_line)
      else
        @cursor_row -= 1
      end
    end

    def erase_display(mode)
      case mode
      when 0
        erase_line(0)
        ((@cursor_row + 1)...rows).each { |row| active_buffer[:lines][row] = blank_line }
      when 1
        erase_line(1)
        (0...@cursor_row).each { |row| active_buffer[:lines][row] = blank_line }
      when 2, 3
        active_buffer[:lines] = Array.new(rows) { blank_line }
        active_buffer[:scrollback].clear if mode == 3
      end
    end

    def erase_line(mode)
      line = active_buffer[:lines][@cursor_row]
      range = case mode
      when 1 then 0..@cursor_col
      when 2 then 0...cols
      else @cursor_col...cols
      end
      range.each { |col| line[col] = blank_cell }
    end

    def set_mode(values, enabled)
      values.each do |mode|
        case mode
        when 25 then @cursor_visible = enabled
        when 47, 1047, 1049
          if enabled
            save_cursor if mode == 1049
            @alternate = new_buffer
            @alternate_active = true
            @cursor_row = @cursor_col = 0
          else
            @alternate_active = false
            restore_cursor if mode == 1049
          end
        end
      end
    end

    def apply_sgr(values)
      values = [ 0 ] if values.empty? || values == [ nil ]
      index = 0
      while index < values.length
        code = values[index] || 0
        case code
        when 0 then reset_attributes
        when 1 then add_style("bold")
        when 2 then add_style("dim")
        when 3 then add_style("italic")
        when 4 then add_style("underline")
        when 5, 6 then add_style("blink")
        when 7 then add_style("inverse")
        when 8 then add_style("hidden")
        when 9 then add_style("strikethrough")
        when 22 then remove_styles("bold", "dim")
        when 23 then remove_styles("italic")
        when 24 then remove_styles("underline")
        when 25 then remove_styles("blink")
        when 27 then remove_styles("inverse")
        when 28 then remove_styles("hidden")
        when 29 then remove_styles("strikethrough")
        when 30..37 then @foreground = ansi_color(code - 30)
        when 40..47 then @background = ansi_color(code - 40)
        when 90..97 then @foreground = ansi_color(code - 90 + 8)
        when 100..107 then @background = ansi_color(code - 100 + 8)
        when 39 then @foreground = nil
        when 49 then @background = nil
        when 38, 48
          color, consumed = extended_color(values, index)
          code == 38 ? @foreground = color : @background = color
          index += consumed
        end
        index += 1
      end
    end

    def extended_color(values, index)
      return [ { mode: "indexed", value: values[index + 2].to_i }, 2 ] if values[index + 1] == 5
      if values[index + 1] == 2
        return [ { mode: "rgb", r: values[index + 2].to_i, g: values[index + 3].to_i, b: values[index + 4].to_i }, 4 ]
      end
      [ nil, 0 ]
    end

    def ansi_color(value) = { mode: "ansi", value: value }
    def add_style(style)
      @styles << style unless @styles.include?(style)
    end

    def remove_styles(*styles)
      @styles -= styles
    end

    def reset_attributes
      @foreground = @background = nil
      @styles = []
    end

    def insert_lines(count)
      count.times { active_buffer[:lines].insert(@cursor_row, blank_line); active_buffer[:lines].pop }
    end

    def delete_lines(count)
      count.times { active_buffer[:lines].delete_at(@cursor_row); active_buffer[:lines] << blank_line }
    end

    def delete_characters(count)
      line = active_buffer[:lines][@cursor_row]
      count.times { line.delete_at(@cursor_col); line << blank_cell }
    end

    def insert_characters(count)
      line = active_buffer[:lines][@cursor_row]
      count.times { line.insert(@cursor_col, blank_cell); line.pop }
    end

    def save_cursor
      @saved_cursor[@alternate_active] = [ @cursor_row, @cursor_col ]
    end

    def restore_cursor
      @cursor_row, @cursor_col = @saved_cursor.fetch(@alternate_active, [ 0, 0 ])
      clamp_cursor
    end

    def reset
      @primary = new_buffer
      @alternate = new_buffer
      @alternate_active = false
      @cursor_row = @cursor_col = 0
      @cursor_visible = true
      reset_attributes
    end

    def active_buffer = @alternate_active ? @alternate : @primary

    def clamp_cursor
      @cursor_row = [[ @cursor_row.to_i, 0 ].max, rows - 1].min
      @cursor_col = [[ @cursor_col.to_i, 0 ].max, cols - 1].min
      @cursor_visible = true if @cursor_visible.nil?
      @alternate_active = false if @alternate_active.nil?
    end

    def trim_scrollback(buffer)
      buffer[:scrollback].shift(buffer[:scrollback].length - @scrollback_limit) if buffer[:scrollback].length > @scrollback_limit
    end

    def serialized_line(line)
      { cells: line.map(&:as_json), text: line.select { |cell| cell.width.positive? }.map(&:text).join.rstrip }
    end
  end
end
