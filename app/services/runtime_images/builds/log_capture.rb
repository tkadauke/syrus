module RuntimeImages
  module Builds
    # Accepts the raw output of a build and keeps a bounded, sanitized copy.
    #
    # Output is sanitized line by line, so a secret is never split across a
    # chunk boundary and then missed. The retained text is capped at +limit+
    # bytes (head kept, remainder counted in #dropped_bytes), lines are capped
    # at MAX_LINE_BYTES, control sequences are stripped, and anything that looks
    # like a credential is replaced before it is stored anywhere.
    class LogCapture
      MAX_LINE_BYTES = 4096
      REDACTED = CommandRedactor::REDACTED
      PRIVATE_KEY_BEGIN = /-----BEGIN [A-Z ]*PRIVATE KEY-----/
      PRIVATE_KEY_END = /-----END [A-Z ]*PRIVATE KEY-----/
      PATTERNS = [
        [ /(authorization|proxy-authorization|x-api-key|cookie|set-cookie)(\s*[:=]\s*).*/i, "\\1\\2#{REDACTED}" ],
        [ /\b(Bearer|Basic|Token)\s+[A-Za-z0-9._~+\/=-]{8,}/i, "\\1 #{REDACTED}" ],
        [ %r{(\b[a-z][a-z0-9+.-]*://[^/\s:@]+:)[^@\s/]+(@)}i, "\\1#{REDACTED}\\2" ],
        [ /\b(AKIA|ASIA)[0-9A-Z]{16}\b/, REDACTED ],
        [ /\b(?:npm|pypi|glpat|xox[abprs]|sk)[_-][A-Za-z0-9_-]{16,}\b/, REDACTED ],
        [ /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/, REDACTED ]
      ].freeze
      # Escape sequences first (so their payload is not left behind), then any
      # remaining control character except tab.
      ANSI = /\e\][^\a\e]*(?:\a|\e\\)?|\e\[[0-9;?]*[ -\/]*[@-~]|\e[@-Z\\-_]/
      CONTROL = /[\x00-\x08\x0b-\x1f\x7f]/

      attr_reader :dropped_bytes, :seen_bytes

      def initialize(limit: Config.build_log_bytes)
        @limit = limit
        @out = +""
        @pending = +"".b
        @seen_bytes = 0
        @dropped_bytes = 0
        @in_private_key = false
      end

      def write(chunk)
        data = chunk.to_s.b
        @seen_bytes += data.bytesize
        @pending << data
        while (index = @pending.index("\n"))
          line = @pending.slice!(0..index)
          emit(line)
        end
        # A single unterminated line must not grow without bound.
        emit(@pending.slice!(0, @pending.bytesize)) if @pending.bytesize > MAX_LINE_BYTES * 4
        self
      end

      # Flushes a trailing unterminated line and returns the sanitized log.
      def finish
        emit(@pending.slice!(0, @pending.bytesize)) unless @pending.empty?
        @out
      end

      def bytes = @out.bytesize

      def self.sanitize_line(line)
        text = line.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
        text = text.gsub(ANSI, "").gsub(CONTROL, "")
        text = CommandRedactor.redact(text)
        PATTERNS.reduce(text) { |current, (pattern, replacement)| current.gsub(pattern, replacement) }
      end

      private

      def emit(raw)
        line = raw.byteslice(0, MAX_LINE_BYTES * 4) || +""
        text = private_key_filtered(self.class.sanitize_line(line).rstrip)
        return if text.nil?

        text = "#{text.byteslice(0, MAX_LINE_BYTES).scrub("")}…" if text.bytesize > MAX_LINE_BYTES
        text = "#{text}\n"
        room = [ @limit - @out.bytesize, 0 ].max
        if text.bytesize <= room
          @out << text
        else
          @out << text.byteslice(0, room).scrub("") if room.positive?
          @dropped_bytes += text.bytesize - room
        end
      end

      # Everything between a PRIVATE KEY header and footer is dropped and the
      # header is replaced by a marker. Returns nil for lines inside the block.
      def private_key_filtered(text)
        if @in_private_key
          @in_private_key = false if text.match?(PRIVATE_KEY_END)
          nil
        elsif text.match?(PRIVATE_KEY_BEGIN)
          @in_private_key = !text.match?(PRIVATE_KEY_END)
          "#{REDACTED} (private key material omitted)"
        else
          text
        end
      end
    end
  end
end
