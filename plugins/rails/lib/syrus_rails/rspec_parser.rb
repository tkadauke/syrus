module SyrusRails
  # Parses RSpec's default progress or documentation formatter output into a
  # normalized TestRun hash. Use this for projects that haven't configured the
  # JUnit formatter; projects that produce --format RspecJunitFormatter output
  # are already handled by core's JUnit parser.
  #
  # TestRun shape:
  #   {
  #     "status"   => "passed" | "failed",
  #     "duration" => Float | nil,
  #     "summary"  => { "total" => Integer, "passed" => Integer,
  #                     "failed" => Integer, "pending" => Integer },
  #     "test_cases" => [TestCase]
  #   }
  #
  # TestCase shape:
  #   {
  #     "name"            => String,
  #     "file_path"       => String | nil,
  #     "line_number"     => Integer | nil,
  #     "status"          => "passed" | "failed" | "pending",
  #     "failure_message" => String | nil
  #   }
  class RspecParser
    # Returns true when this parser can handle the given output file.
    def self.can_parse?(output_path:, format_hint: nil)
      return true if format_hint.to_s == "rspec"

      content = File.read(output_path.to_s)
      content.match?(/\d+ examples?/) && content.match?(/failure|pending/i)
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def self.call(output_path:, format_hint: nil)
      new(File.read(output_path.to_s)).parse
    end

    def initialize(content)
      @content = content
    end

    def parse
      summary    = parse_summary
      test_cases = parse_failures

      {
        "status"     => test_cases.any? { |tc| tc["status"] == "failed" } ? "failed" : "passed",
        "duration"   => summary[:duration],
        "summary"    => {
          "total"   => summary[:total],
          "passed"  => summary[:passed],
          "failed"  => summary[:failed],
          "pending" => summary[:pending]
        },
        "test_cases" => test_cases
      }
    end

    private

    SUMMARY_PATTERN = /(\d+) examples?, (\d+) failures?(?:, (\d+) pending)?/
    DURATION_PATTERN = /Finished in ([\d.]+) seconds/

    def parse_summary
      if (m = @content.match(SUMMARY_PATTERN))
        total   = m[1].to_i
        failed  = m[2].to_i
        pending = m[3].to_i
        passed  = [total - failed - pending, 0].max
      else
        total = failed = pending = passed = 0
      end

      duration = @content.match(DURATION_PATTERN)&.then { |d| d[1].to_f }

      { total: total, failed: failed, pending: pending, passed: passed, duration: duration }
    end

    # Each failure block in RSpec output looks like:
    #
    #   1) Group description example description
    #      Failure/Error: some_expression
    #
    #        error message
    #        on multiple lines
    #
    #      # ./spec/path_spec.rb:10:in 'block'
    #
    FAILURE_HEADER = /^\s{2,}\d+\) /

    def parse_failures
      # Locate the Failures: section first; parse only within it.
      failures_section = @content[/^Failures:\s*\n(.+?)(?=\n\n[A-Z]|\z)/m, 1].to_s

      blocks = split_failure_blocks(failures_section)
      blocks.map { |block| build_test_case(block) }
    end

    def split_failure_blocks(section)
      # Split on lines that start a new numbered failure ("  1) ", "  2) " …)
      blocks = []
      current = nil

      section.each_line do |line|
        if line.match?(FAILURE_HEADER)
          blocks << current if current
          current = line
        elsif current
          current << line
        end
      end
      blocks << current if current
      blocks.compact
    end

    def build_test_case(block)
      lines = block.lines

      # First line: "  1) Full test description"
      name = lines.first&.sub(/^\s*\d+\)\s*/, "")&.strip.to_s

      # Find location line: "     # ./spec/...:NN:in ..."
      location_line = lines.find { |l| l.match?(%r{#\s+\./}) }
      file_path, line_number = extract_location(location_line)

      # Failure message: lines between the header and the location line,
      # excluding blank lines and the "Failure/Error:" header itself.
      msg_lines = lines[1..]
        &.take_while { |l| !l.match?(%r{#\s+\./}) }
        &.map(&:strip)
        &.reject(&:empty?) || []
      failure_message = msg_lines.join("\n").presence

      {
        "name"            => name,
        "file_path"       => file_path,
        "line_number"     => line_number,
        "status"          => "failed",
        "failure_message" => failure_message
      }
    end

    def extract_location(line)
      return [nil, nil] if line.nil?

      if (m = line.match(%r{#\s+\./(spec/[^\s:]+):(\d+)}))
        [m[1], m[2].to_i]
      else
        [nil, nil]
      end
    end
  end
end
