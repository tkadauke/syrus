# frozen_string_literal: true

module Deploy
  # Operator-facing durations. Every timeout knob accepts either a bare number
  # of seconds or a compound `1h30m` form, because both spellings already exist
  # across the deploy's environment variables and its kubectl arguments.
  #
  # Parsing is strict and happens once, before anything touches a cluster. A
  # typo'd `ROLLOUT_TIMEOUT=15n` has to fail at startup; discovering it an hour
  # in, with Flux suspended and half the pods replaced, is the whole reason
  # this is validated eagerly rather than at each use.
  module Duration
    class Invalid < ArgumentError; end

    SECONDS_PER_UNIT = { "h" => 3600, "m" => 60, "s" => 1 }.freeze
    COMPOUND = /\A(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?\z/

    class << self
      def seconds(value, name: nil)
        text = value.to_s.strip
        return Integer(text, 10) if text.match?(/\A\d+\z/)

        match = COMPOUND.match(text)
        raise Invalid, message(text, name) if match.nil? || text.empty?

        hours, minutes, secs = match.captures.map { |part| part ? Integer(part, 10) : 0 }
        hours * 3600 + minutes * 60 + secs
      end

      # kubectl's own `--timeout` flag wants a Go duration, and `90` is not one.
      def to_kubectl(seconds)
        "#{Integer(seconds)}s"
      end

      def humanize(seconds)
        seconds = Integer(seconds)
        parts = []
        SECONDS_PER_UNIT.each do |unit, size|
          next if seconds < size

          parts << "#{seconds / size}#{unit}"
          seconds %= size
        end
        parts.empty? ? "0s" : parts.join
      end

      private

      def message(text, name)
        subject = name ? "#{name}=#{text.inspect}" : text.inspect
        "invalid duration #{subject}; use seconds or a compound duration such as 1h30m"
      end
    end
  end
end
