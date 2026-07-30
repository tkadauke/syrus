require "rexml/document"

# Parses JUnit XML output files into structured data for TestRun/TestCase ingestion.
#
# Handles both <testsuites> wrapper and bare <testsuite> documents. Gracefully
# skips malformed XML rather than raising so a broken results file never blocks
# the grader step from being recorded.
class JunitXmlParser
  ParseError = Class.new(StandardError)

  # Aggregate result across all suites in the document.
  ParsedRun = Data.define(
    :total_count, :passed_count, :failed_count, :skipped_count, :error_count,
    :duration_ms, :cases
  )

  ParsedCase = Data.define(
    :name, :suite_name, :file_path, :status,
    :duration_ms, :output, :failure_message, :failure_backtrace
  )

  def self.parse(xml_content)
    new(xml_content).parse
  end

  def initialize(xml_content)
    @xml_content = xml_content
  end

  def parse
    doc = REXML::Document.new(@xml_content)
    root = doc.root
    raise ParseError, "empty or non-XML document" if root.nil?

    suites =
      case root.name
      when "testsuites"
        root.elements.to_a("testsuite")
      when "testsuite"
        [ root ]
      else
        raise ParseError, "unexpected root element: #{root.name.inspect}"
      end

    cases = suites.flat_map { |suite| parse_suite(suite) }

    total    = cases.size
    passed   = cases.count { |c| c.status == "passed" }
    failed   = cases.count { |c| c.status == "failed" }
    skipped  = cases.count { |c| c.status == "skipped" }
    errors   = cases.count { |c| c.status == "error" }
    duration = total_duration_ms(suites)

    ParsedRun.new(
      total_count: total,
      passed_count: passed,
      failed_count: failed,
      skipped_count: skipped,
      error_count: errors,
      duration_ms: duration,
      cases: cases
    )
  rescue REXML::ParseException => e
    raise ParseError, "XML parse error: #{e.message}"
  end

  private

  def parse_suite(suite)
    suite_name = suite.attributes["name"].to_s.strip.presence || "unknown"

    suite.elements.to_a("testcase").map do |tc|
      parse_testcase(tc, suite_name)
    end
  end

  def parse_testcase(tc, suite_name)
    name       = tc.attributes["name"].to_s.strip.presence || "unnamed"
    classname  = tc.attributes["classname"].to_s.strip.presence || suite_name
    file_path  = tc.attributes["file"].to_s.strip.presence
    duration   = parse_duration_ms(tc.attributes["time"])

    failure  = tc.elements["failure"]
    error    = tc.elements["error"]
    skipped  = tc.elements["skipped"] || tc.elements["skip"]

    status, failure_message, failure_backtrace =
      if error
        [ "error", element_message(error), element_body(error) ]
      elsif failure
        [ "failed", element_message(failure), element_body(failure) ]
      elsif skipped
        [ "skipped", nil, nil ]
      else
        [ "passed", nil, nil ]
      end

    output = combined_output(tc)

    ParsedCase.new(
      name: name,
      suite_name: classname,
      file_path: file_path,
      status: status,
      duration_ms: duration,
      output: output.presence,
      failure_message: failure_message,
      failure_backtrace: failure_backtrace
    )
  end

  def element_message(el)
    el.attributes["message"].to_s.strip.presence
  end

  def element_body(el)
    el.text.to_s.strip.presence
  end

  def combined_output(tc)
    parts = []
    parts << tc.elements["system-out"]&.text.to_s.strip
    parts << tc.elements["system-err"]&.text.to_s.strip
    parts.reject(&:empty?).join("\n")
  end

  def parse_duration_ms(raw)
    return nil if raw.nil? || raw.to_s.strip.empty?
    seconds = Float(raw.to_s)
    (seconds * 1000).round
  rescue ArgumentError
    nil
  end

  def total_duration_ms(suites)
    total = suites.sum do |suite|
      parse_duration_ms(suite.attributes["time"]) || 0
    end
    total.positive? ? total : nil
  end
end
