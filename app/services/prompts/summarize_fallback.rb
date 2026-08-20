module Prompts
  # Bounded summarize prompt. Summarize intentionally does not resume the
  # implementation session: metadata-only steps are safer and cheaper when
  # they get explicit job context plus a changed-file manifest instead of a
  # long coding transcript that can accidentally continue implementation.
  class SummarizeFallback
    MAX_BODY_BYTES = 16 * 1024
    MAX_CHANGED_FILES = 200

    def initialize(issue:, diff:)
      @issue = issue
      @diff = diff.to_s
    end

    def to_s
      <<~PROMPT.strip
        You are running the summarize step for a Syrus job. The implementation
        step already committed the work. Use this bounded metadata-only context
        to produce PR copy.

        Produce the PR copy by calling the `submit_summary` MCP tool with
        three fields. If your tool list shows a prefixed MCP name, call the
        exact prefixed name shown there; do not call bare `submit_summary`
        unless that exact bare name is available.

        - `pr_title`: 50-72 chars, imperative mood ("Add greeting helper",
          not "Adds..." or "This PR adds..."). No leading prefix or repo slug.
        - `pr_body`: markdown, 1-3 short paragraphs. Lead with the why; then
          mention what changed. No headings, no "This PR..." preamble.
        - `summary`: 1-2 sentences, operator-facing, shown on the Syrus job page.

        Do not edit files, run commands, or make commits. Do not continue
        implementation. Just call the available `submit_summary` tool name and
        exit.

        # Original job
        Title: #{@issue.title}

        Body:
        #{trimmed_body}

        # Changed files
        #{changed_file_manifest}
      PROMPT
    end

    private

    def trimmed_body
      body = @issue.body.to_s.strip
      return "(empty)" if body.blank?
      return body if body.bytesize <= MAX_BODY_BYTES

      "#{body.safe_byteslice(0, MAX_BODY_BYTES)}\n...[truncated, #{body.bytesize - MAX_BODY_BYTES} more bytes]"
    end

    def changed_file_manifest
      files = changed_files
      return "- (No changed files captured.)" if files.empty?

      lines = files.first(MAX_CHANGED_FILES).map do |file|
        "- #{file[:path]} (#{file[:bytes]} diff bytes)"
      end
      if files.size > MAX_CHANGED_FILES
        lines << "- ... #{files.size - MAX_CHANGED_FILES} more file(s) omitted from this manifest"
      end
      lines.join("\n")
    end

    def changed_files
      @diff.split(/(?=^diff --git )/)
        .map(&:strip)
        .reject(&:empty?)
        .filter_map do |section|
          path = section.lines.first.to_s[/\Adiff --git a\/.+ b\/(.+)\s*\z/, 1]
          next if path.blank?

          { path: path, bytes: section.bytesize }
        end
    end
  end
end
