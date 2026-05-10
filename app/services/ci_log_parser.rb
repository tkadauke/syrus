class CiLogParser
  MAX_BLOCK_LINES = 80
  FALLBACK_CONTEXT_LINES = 40

  FAILURE_MARKER = /
    failures?:|failed\sexamples?|offenses?:|error:|exception|traceback|
    assertionerror|typeerror|referenceerror|syntaxerror|ts\d{4}|exit\scode
  /ix

  def initialize(log, step_name:, full_log_url: nil)
    @log = log.to_s.delete("\r")
    @step_name = step_name.to_s
    @full_log_url = full_log_url
  end

  def parse
    return base_result(parser: "empty", error_summary: "No CI log was available.", error_block: "") if @log.blank?

    scoped = scoped_log
    parse_rspec(scoped) ||
      parse_minitest(scoped) ||
      parse_rubocop(scoped) ||
      parse_js_test(scoped) ||
      parse_typescript(scoped) ||
      parse_generic_error(scoped) ||
      parse_fallback(scoped)
  end

  private

  def base_result(parser:, error_summary:, error_block:, **extra)
    {
      failing_step: @step_name.presence,
      parser: parser,
      error_summary: error_summary.to_s.strip,
      failing_tests: [],
      offenses: [],
      error_block: trim_block(error_block),
      full_log_url: @full_log_url
    }.merge(extra).compact
  end

  def scoped_log
    return @log if @step_name.blank?

    lines = @log.lines
    marker_index = lines.find_index { |line| line.match?(/(^|\b)(run|step|name):?\s+#{Regexp.escape(@step_name)}\b/i) || line.include?("##[group]#{@step_name}") }
    return @log unless marker_index

    tail = lines[marker_index..]
    next_group = tail[1..]&.find_index { |line| line.start_with?("##[group]") || line.match?(/^\s*(run|step|name):\s+/i) }
    next_group ? tail[0..next_group].join : tail.join
  end

  def parse_rspec(text)
    return unless text.match?(/^\s*Failures:\s*$/)

    block = slice_between(text, /^\s*Failures:\s*$/, /^\s*(Finished in|Top \d+ slowest examples|Failed examples:|Randomized with seed)/)
    tests = block.scan(/^\s+\d+\)\s+(.+?)\s*$/).flatten
    failed_examples = text.scan(/^\s*rspec\s+(.+?)\s+#\s+(.+?)\s*$/).map { |path, name| "#{path} - #{name}" }
    tests = (tests + failed_examples).uniq
    summary = text[/\d+\s+examples?,\s+\d+\s+failures?(?:,\s+\d+\s+pending)?/i] || "#{tests.size} RSpec failure(s)"

    base_result(parser: "rspec", error_summary: summary, error_block: block, failing_tests: tests)
  end

  def parse_minitest(text)
    return unless text.match?(/^\s*\d+\)\s+(Failure|Error):/)

    block = slice_between(text, /^\s*\d+\)\s+(Failure|Error):/, /^\s*\d+\s+runs?,\s+\d+\s+assertions?,/)
    tests = block.scan(/^\s*\d+\)\s+(?:Failure|Error):\s*([^\n]+)/).flatten
    summary = text[/\d+\s+runs?,\s+\d+\s+assertions?,\s+\d+\s+failures?,\s+\d+\s+errors?(?:,\s+\d+\s+skips?)?/i] || "#{tests.size} MiniTest failure(s)"

    base_result(parser: "minitest", error_summary: summary, error_block: block, failing_tests: tests)
  end

  def parse_rubocop(text)
    offense_lines = text.lines.select { |line| line.match?(/^[^:\n]+:\d+:\d+:\s+[A-Z]:\s+/) }
    return if offense_lines.empty?

    summary = text[/\d+\s+files?\s+inspected,\s+\d+\s+offenses?\s+detected/i] || "#{offense_lines.size} RuboCop offense(s)"
    base_result(parser: "rubocop", error_summary: summary, error_block: offense_lines.join, offenses: offense_lines.map(&:strip))
  end

  def parse_js_test(text)
    return unless text.match?(/^\s*(FAIL|Failed)\s+/) || text.match?(/^\s*[-\s]*\d+\s+failed\b/i)

    lines = text.lines
    start = lines.find_index { |line| line.match?(/^\s*(FAIL|Failed)\s+/) || line.match?(/^\s*[●>]\s+/) } || 0
    block = lines[start, MAX_BLOCK_LINES].join
    tests = block.scan(/^\s*[●>]\s+(.+?)\s*$/).flatten
    tests += block.scan(/^\s*FAIL\s+(.+?)\s*$/).flatten
    summary = text[/Test Files\s+\d+\s+failed.*$/i] || text[/Tests\s+\d+\s+failed.*$/i] || text[/\d+\s+failed\b.*$/i] || "#{tests.size} JS test failure(s)"

    base_result(parser: "js_test", error_summary: summary, error_block: block, failing_tests: tests.uniq)
  end

  def parse_typescript(text)
    error_lines = text.lines.select { |line| line.match?(/\bTS\d{4}:/) || line.match?(/:\d+:\d+\s+-\s+error\s+TS\d{4}:/) }
    return if error_lines.empty?

    base_result(parser: "typescript", error_summary: "#{error_lines.size} TypeScript error(s)", error_block: error_lines.join)
  end

  def parse_generic_error(text)
    lines = text.lines
    index = lines.find_index { |line| line.match?(/\b(Error|Exception|Traceback|failed with exit code|Process completed with exit code)\b/i) }
    return unless index

    block = lines[[index - 5, 0].max, FALLBACK_CONTEXT_LINES].join
    summary = lines[index].strip.sub(/\A\[[^\]]+\]\s*/, "")
    base_result(parser: "generic_error", error_summary: summary, error_block: block)
  end

  def parse_fallback(text)
    lines = text.lines
    index = lines.rindex { |line| line.match?(FAILURE_MARKER) } || [lines.length - FALLBACK_CONTEXT_LINES, 0].max
    start = [index - (FALLBACK_CONTEXT_LINES / 2), 0].max
    block = lines[start, FALLBACK_CONTEXT_LINES].join
    summary = lines[index]&.strip.presence || "CI failed, but no known error pattern matched."

    base_result(parser: "fallback", error_summary: summary, error_block: block)
  end

  def slice_between(text, start_pattern, end_pattern)
    lines = text.lines
    start = lines.find_index { |line| line.match?(start_pattern) } || 0
    finish = lines[(start + 1)..]&.find_index { |line| line.match?(end_pattern) }
    finish ? lines[start, finish + 1].join : lines[start, MAX_BLOCK_LINES].join
  end

  def trim_block(block)
    lines = block.to_s.lines
    trimmed = lines.first(MAX_BLOCK_LINES).join.rstrip
    trimmed += "\n...[truncated]" if lines.length > MAX_BLOCK_LINES
    trimmed
  end
end
