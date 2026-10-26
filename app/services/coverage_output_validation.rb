require "json"

# A deliberately small allowlist for files that may cross the immutable
# checkout boundary. Declaring coverage_outputs is repository-controlled, so
# collection must prove that a file looks like the named coverage format; a
# path inside the checkout is not sufficient authorization by itself.
module CoverageOutputValidation
  MAX_BYTES = 100.megabytes
  SAMPLE_BYTES = 64.kilobytes

  Result = Data.define(:valid, :reason) do
    def valid? = valid
  end

  class Base
    def self.for(format)
      FORMATS[format.to_s]&.new
    end

    def validate(path)
      return invalid("file is empty") unless path.size.positive?
      return invalid("file exceeds #{MAX_BYTES} bytes") if path.size > MAX_BYTES
      return invalid("filename is not valid for #{format}") unless valid_filename?(path.basename.to_s)
      return invalid("content is not valid for #{format}") unless valid_content?(path)

      Result.new(valid: true, reason: nil)
    end

    private

    def sample(path) = path.open("rb") { |file| file.read(SAMPLE_BYTES).to_s }
    def invalid(reason) = Result.new(valid: false, reason:)
  end

  class Lcov < Base
    private

    def format = "lcov"
    def valid_filename?(name) = name.end_with?(".info")

    def valid_content?(path)
      content = sample(path)
      content.match?(/^SF:.+/) && content.match?(/^DA:\d+,\d+/)
    end
  end

  class Cobertura < Base
    private

    def format = "cobertura"
    def valid_filename?(name) = name.end_with?(".xml")
    def valid_content?(path) = sample(path).match?(/<coverage(?:\s|>)/)
  end

  class GoCover < Base
    private

    def format = "go-cover"
    def valid_filename?(name) = name.end_with?(".out", ".cover", ".cov")
    def valid_content?(path) = sample(path).match?(/\Amode: (?:set|count|atomic)\s*$/)
  end

  class SimpleCov < Base
    private

    def format = "simplecov"
    def valid_filename?(name) = name == ".resultset.json"

    def valid_content?(path)
      data = JSON.parse(path.read)
      data.is_a?(Hash) && data.values.any? do |result|
        result.is_a?(Hash) && result["coverage"].is_a?(Hash)
      end
    rescue JSON::ParserError
      false
    end
  end

  FORMATS = {
    "lcov" => Lcov,
    "cobertura" => Cobertura,
    "go-cover" => GoCover,
    "simplecov" => SimpleCov
  }.freeze
end
