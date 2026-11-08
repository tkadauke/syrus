module Coworkers
  # Single boundary for external strings entering coworker prompts. Sources such
  # as `IO#read(length)`, `File.binread`, git output, and JSON blobs can yield
  # ASCII-8BIT or invalid UTF-8 strings that raise
  # Encoding::CompatibilityError when joined with UTF-8 text.
  class Utf8Text
    REPLACEMENT = "�".freeze

    Result = Struct.new(:text, :lossy, :binary, keyword_init: true) do
      alias_method :lossy?, :lossy
      alias_method :binary?, :binary
    end

    class << self
      def normalize(value)
        string = value.to_s
        return Result.new(text: +"", lossy: false, binary: false) if string.empty?

        if string.include?("\0")
          return Result.new(text: +"", lossy: false, binary: true)
        end

        candidate = string.dup
        candidate.force_encoding(Encoding::UTF_8) if candidate.encoding == Encoding::BINARY
        return Result.new(text: candidate, lossy: false, binary: false) if candidate.encoding == Encoding::UTF_8 && candidate.valid_encoding?

        text = if candidate.encoding == Encoding::UTF_8
          candidate.scrub(REPLACEMENT)
        else
          candidate.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
        end
        Result.new(text: text.scrub(REPLACEMENT), lossy: true, binary: false)
      end

      def scrub(value) = normalize(value).text
    end
  end
end
