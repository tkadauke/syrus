module Prompts
  class AdversarialReview
    MAX_CHANGED_FILES = 200

    FEEDBACK_KIND_LABELS = {
      chat_feedback: { context: "chat feedback",       history: "Chat feedback being addressed" },
      pr_comment:    { context: "PR comment feedback", history: "PR comments being addressed"   }
    }.freeze

    def initialize(issue:, diff:, prior_findings:, workflow_kind: nil, feedback_context: nil, criteria: [])
      @issue = issue
      @diff = diff.to_s
      @prior_findings = Array(prior_findings)
      @workflow_kind = workflow_kind.to_s
      @feedback_context = feedback_context.to_s
      @criteria = Array(criteria)
    end

    def to_s
      [
        "You are running the adversarial_review step for Syrus.",
        independence,
        custom_criteria,
        workflow_context,
        job_context,
        feedback_history,
        change_manifest,
        prior_review_context,
        submission_instructions
      ].compact_blank.join("\n\n")
    end

    private

    def feedback_kind
      Workflow::TriggerKind.feedback_kind_for(@workflow_kind)
    end

    def feedback_workflow?
      feedback_kind.present?
    end

    def custom_criteria
      return nil if @criteria.empty?

      lines = @criteria.map { |c| "- #{c}" }.join("\n")
      "In addition to general review concerns, pay particular attention to the following criteria:\n#{lines}"
    end

    def independence
      <<~TEXT.strip
        Approach this code as an independent reviewer with no knowledge of how the implementing agent reasoned.
        Use the full tool access available to inspect files, run commands, and probe behavior.
        Look for bugs, missing edge cases, regressions, unclear behavior, weak tests, and maintainability issues.
        Do not make code changes; any edits you make are ephemeral and will not be committed.
      TEXT
    end

    def workflow_context
      return nil unless feedback_workflow?

      kind_label = FEEDBACK_KIND_LABELS.fetch(feedback_kind)[:context]
      "This is a #{kind_label} workflow. The changes under review address operator feedback on an existing PR, not a fresh implementation."
    end

    def job_context
      [
        "Job description:",
        "Title: #{@issue.title.presence || '(No title provided.)'}",
        @issue.body.presence || "(No body provided.)"
      ].join("\n\n")
    end

    def feedback_history
      return nil unless feedback_workflow? && @feedback_context.present?

      label = FEEDBACK_KIND_LABELS.fetch(feedback_kind)[:history]
      "#{label}:\n\n#{@feedback_context}"
    end

    def change_manifest
      agentic_label = feedback_workflow? ? "respond" : "implement"
      files = changed_files
      file_lines =
        if files.empty?
          [ "- (No changed files captured.)" ]
        else
          rendered = files.first(MAX_CHANGED_FILES).map do |file|
            "- #{file[:path]} (#{file[:bytes]} diff bytes)"
          end
          if files.size > MAX_CHANGED_FILES
            rendered << "- ... #{files.size - MAX_CHANGED_FILES} more file(s) omitted from this manifest"
          end
          rendered
        end

      [
        "Changed files from the latest succeeded #{agentic_label} step:",
        *file_lines,
        "",
        "Do not rely on this manifest alone. Inspect the workspace directly before deciding:",
        "- Run `git diff <base>...HEAD -- <path>` for the files that matter.",
        "- Read the current source files and related tests with normal file tools.",
        "- Use broad searches when the changed-file list suggests cross-cutting behavior.",
        "- Treat generated artifacts as validation targets, not primary review input."
      ].join("\n")
    end

    def changed_files
      split_diff_sections(@diff).filter_map do |section|
        path = section_path(section)
        next if path.blank?

        { path: path, bytes: section.bytesize }
      end
    end

    def split_diff_sections(diff)
      diff.to_s.split(/(?=^diff --git )/)
        .map(&:strip)
        .reject(&:empty?)
    end

    def section_path(section)
      header = section.lines.first.to_s
      header[/\Adiff --git a\/.+ b\/(.+)\s*\z/, 1]
    end

    def prior_review_context
      return "Prior adversarial review findings: none." if @prior_findings.empty?

      [
        "Prior adversarial review findings:",
        @prior_findings.map { |finding| render_finding(finding) }.join("\n\n")
      ].join("\n\n")
    end

    def render_finding(finding)
      iteration = finding["iteration"] || finding[:iteration] || "unknown"
      verdict = finding["verdict"] || finding[:verdict] || "unknown"
      critique = finding["critique"] || finding[:critique] || "(No critique provided.)"

      "Iteration #{iteration} (#{verdict}):\n#{critique}"
    end

    def submission_instructions
      <<~TEXT.strip
        When finished, call the `submit_adversarial_review` MCP tool exposed by `syrus-mcp-sidecar` with the exact name shown in your tool list. Do not call bare `submit_adversarial_review` unless that exact bare name is available.
        - critique: concise Markdown describing concrete findings, or a short note that you found no blocking issues.
        - verdict: "needs_work" when implementation changes are needed, otherwise "approved".

        The verdict is recorded for future workflow control but is not acted on yet.

        Do not wait on long background commands or optional long-running builds before calling this tool. If you have enough evidence to decide, submit the review immediately; if verification is inconclusive but you found no concrete blocker, use verdict "approved" and mention the incomplete verification in the critique.

        Do not call `ReportFindings` or any other generic findings-reporting tool — this step is only complete once `submit_adversarial_review` has been called.
      TEXT
    end
  end
end
