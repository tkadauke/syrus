require "mcp"

module Mcp::Tools
  class ReadCiLogTool < MCP::Tool
    DEFAULT_TAIL_LINES = 200
    MAX_LINES = 2_000
    MATCH_CONTEXT_LINES = 3

    tool_name "read_ci_log"

    description <<~DESC
      Read the log of one CI check on this Job's pull request head (or
      another pull request in the same repository). Returns the last
      tail_lines lines, or, with match, only the lines containing that text
      (case-insensitive) with a few lines of context. Use list_ci_checks to
      find check names. Read-only; uses Syrus's own GitHub access, so no gh
      CLI or token is needed. Secrets are redacted.
    DESC

    input_schema(
      properties: {
        check_name: { type: "string", description: "Exact check name from list_ci_checks." },
        pr_number: { type: "integer", description: "Pull request number. Defaults to this Job's pull request." },
        tail_lines: { type: "integer", description: "How many trailing lines to return (default #{DEFAULT_TAIL_LINES}, max #{MAX_LINES})." },
        match: { type: "string", description: "Return only lines containing this text, with surrounding context." }
      },
      required: %w[check_name]
    )

    class << self
      def call(check_name:, server_context:, pr_number: nil, tail_lines: nil, match: nil)
        target = CiCheckLookup.target(server_context, pr_number:)
        return target if target.is_a?(MCP::Tool::Response)

        checks = CiCheckLookup.checks(target)
        check = checks.find { |entry| entry[:name] == check_name.to_s }
        unless check
          names = checks.map { |entry| entry[:name] }.uniq.first(30)
          return Mcp::Tools.invalid("no check named #{check_name.inspect} on ##{target.pr_number}; checks: #{names.join(', ')}")
        end

        log = check[:actions_job_id] ? target.client.ci_job_log(target.repository.slug, check[:actions_job_id]) : nil
        source = log.present? ? "actions_job_log" : "check_output"
        log = check[:output_text] if log.blank?
        if log.blank?
          return Mcp::Tools.invalid("GitHub has no readable log for #{check_name.inspect}; it may have expired. Open #{check[:html_url]} only if an operator can.")
        end

        lines = ToolPayloadRedactor.redact_text(log.to_s).lines.map(&:chomp)
        selected, truncated = select_lines(lines, tail_lines:, match:)

        Mcp::Tools.success(
          check_name: check[:name],
          conclusion: check[:conclusion].presence,
          html_url: check[:html_url],
          source: source,
          total_lines: lines.size,
          returned_lines: selected.size,
          truncated: truncated,
          log: selected.join("\n")
        )
      rescue Octokit::Error => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def select_lines(lines, tail_lines:, match:)
        if match.present?
          needle = match.to_s.downcase
          keep = Set.new
          lines.each_with_index do |line, index|
            next unless line.downcase.include?(needle)

            ((index - MATCH_CONTEXT_LINES)..(index + MATCH_CONTEXT_LINES)).each { |i| keep << i if i.between?(0, lines.size - 1) }
          end
          picked = keep.sort.map { |i| lines[i] }
          return [ picked.first(MAX_LINES), picked.size > MAX_LINES ]
        end

        count = (tail_lines.presence || DEFAULT_TAIL_LINES).to_i.clamp(1, MAX_LINES)
        [ lines.last(count), lines.size > count ]
      end
    end
  end
end
