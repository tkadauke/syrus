module Prompts
  class VisualReview
    FEEDBACK_KIND_LABELS = {
      chat_feedback: { context: "chat feedback",       history: "Chat feedback being addressed" },
      pr_comment:    { context: "PR comment feedback", history: "PR comments being addressed"   }
    }.freeze

    DESKTOP_VIEWPORT = { width: 1280, height: 800 }.freeze
    MOBILE_VIEWPORT = { width: 390, height: 844 }.freeze
    FULL_DIFF_CHARACTER_LIMIT = 40_000
    SUMMARIZED_DIFF_CHARACTER_LIMIT = 24_000
    FILE_LIST_LIMIT = 80
    PER_FILE_EXCERPT_LIMIT = 6_000
    UI_RELEVANT_PATH = %r{
      (^|/)
      (
        app/frontend|
        app/assets|
        app/javascript|
        app/views|
        components|
        frontend|
        javascript|
        pages|
        stylesheets|
        templates|
        views
      )/
    }ix
    UI_RELEVANT_EXTENSION = /\.(css|erb|haml|html|js|jsx|liquid|scss|slim|svelte|ts|tsx|vue)\z/i
    LOW_SIGNAL_EXTENSION = /\.(csv|json|lock|log|sql|tsbuildinfo|txt|ya?ml)\z/i

    def initialize(issue:, diff:, prior_findings:, workflow_kind: nil, feedback_context: nil,
                   test_plan_recommended: nil, test_plan_reason: nil, seed_notes: nil)
      @issue = issue
      @diff = diff.to_s
      @prior_findings = Array(prior_findings)
      @workflow_kind = workflow_kind.to_s
      @feedback_context = feedback_context.to_s
      @test_plan_recommended = test_plan_recommended
      @test_plan_reason = test_plan_reason.to_s
      @seed_notes = seed_notes.to_s
    end

    def to_s
      [
        "You are running the visual_review step for Syrus.",
        independence,
        workflow_context,
        job_context,
        feedback_history,
        current_diff,
        implementer_test_plan_hint,
        seed_notes_section,
        workflow_instructions,
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

    def independence
      <<~TEXT.strip
        You are an independent visual QA reviewer with no knowledge of how the implementing agent
        reasoned. You have your own headless browser tools and shell access to the same workspace
        the implementer used. Your job is to catch visible defects — broken layout, missing content,
        console errors, incorrect rendering, broken interactions — that only show up when the app is
        actually running, not just from reading the diff.
        Do not make code changes; any edits you make are ephemeral and will not be committed.
        Do not run builds, test suites, graders, typecheckers, linters, or other deterministic
        verification commands. Those belong to Syrus grader steps. Use shell only for lightweight,
        review-specific setup such as reading files, inspecting logs, or applying documented seed
        commands needed to reach a preview state.
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

    def current_diff
      agentic_label = feedback_workflow? ? "respond" : "implement"
      [
        current_diff_label(agentic_label),
        "```diff",
        diff_context,
        "```"
      ].join("\n")
    end

    def current_diff_label(agentic_label)
      return "Current diff from the latest succeeded #{agentic_label} step:" unless oversized_diff?

      "Current diff summary from the latest succeeded #{agentic_label} step (bounded for visual review prompt budget):"
    end

    def diff_context
      return "(No diff captured.)" if @diff.blank?
      return @diff unless oversized_diff?

      [
        "Full diff omitted because it is #{@diff.length} characters, above the #{FULL_DIFF_CHARACTER_LIMIT} character visual_review prompt budget.",
        "Changed files:",
        changed_file_lines,
        "",
        "UI-relevant diff excerpts:",
        summarized_diff_excerpt
      ].compact.join("\n")
    end

    def oversized_diff?
      @diff.length > FULL_DIFF_CHARACTER_LIMIT
    end

    def changed_file_lines
      files = changed_files
      return "(Could not identify changed files from diff headers.)" if files.empty?

      lines = files.first(FILE_LIST_LIMIT).map { |file| "- #{file}" }
      omitted = files.size - FILE_LIST_LIMIT
      lines << "- ... #{omitted} more files omitted" if omitted.positive?
      lines.join("\n")
    end

    def changed_files
      @changed_files ||= diff_file_sections.map(&:path).compact_blank.uniq
    end

    def summarized_diff_excerpt
      excerpts = diff_file_sections
        .sort_by { |section| section.ui_relevant? ? 0 : 1 }
        .filter_map(&:excerpt)

      return "(No compact diff excerpt available; rely on changed file names and inspect the workspace directly.)" if excerpts.empty?

      excerpt = +""
      excerpts.each do |candidate|
        remaining = SUMMARIZED_DIFF_CHARACTER_LIMIT - excerpt.length
        break if remaining <= 0

        excerpt << "\n" if excerpt.present?
        excerpt << candidate.first(remaining)
      end
      excerpt << "\n... additional diff hunks omitted for prompt budget" if excerpt.length >= SUMMARIZED_DIFF_CHARACTER_LIMIT
      excerpt
    end

    DiffFileSection = Data.define(:path, :lines) do
      def ui_relevant?
        path.to_s.match?(Prompts::VisualReview::UI_RELEVANT_PATH) ||
          path.to_s.match?(Prompts::VisualReview::UI_RELEVANT_EXTENSION)
      end

      def excerpt
        kept = lines.select do |line|
          line.start_with?("diff --git ", "@@ ", "+++ ", "--- ") ||
            ui_relevant? ||
            (line.start_with?("+", "-") && !path.to_s.match?(Prompts::VisualReview::LOW_SIGNAL_EXTENSION))
        end
        return nil if kept.empty?

        text = kept.join("\n")
        text = "#{text.first(Prompts::VisualReview::PER_FILE_EXCERPT_LIMIT)}\n... file excerpt omitted for prompt budget" if text.length > Prompts::VisualReview::PER_FILE_EXCERPT_LIMIT
        text
      end
    end

    def diff_file_sections
      @diff_file_sections ||= begin
        sections = []
        current_path = nil
        current_lines = []

        @diff.each_line(chomp: true) do |line|
          if line.start_with?("diff --git ")
            sections << DiffFileSection.new(path: current_path, lines: current_lines) if current_lines.any?
            current_path = line[/\Ab\/(.+)\z/, 1] || line.split.last&.sub(/\Ab\//, "")
            current_lines = [ line ]
          else
            current_lines << line
          end
        end

        sections << DiffFileSection.new(path: current_path, lines: current_lines) if current_lines.any?
        sections
      end
    end

    def implementer_test_plan_hint
      return nil if @test_plan_recommended.nil? && @test_plan_reason.blank?

      recommendation =
        case @test_plan_recommended
        when true  then "recommended running visual review"
        when false then "did NOT recommend running visual review"
        else "gave no explicit recommendation"
        end

      <<~TEXT.strip
        The implementing agent #{recommendation} for this change#{@test_plan_reason.present? ? ", with this reasoning:" : "."}
        #{@test_plan_reason.presence}

        Treat this as a hint, not a directive — form your own independent judgment about whether
        this change is visually testable before deciding whether to launch a browser.
      TEXT
    end

    def seed_notes_section
      return nil if @seed_notes.blank?

      "Repository seed notes (from .syrus.yml visual_review.seed_notes), for reaching an authenticated or populated preview state:\n\n#{@seed_notes}"
    end

    def workflow_instructions
      <<~TEXT.strip
        Work through these steps in order:

        1. Decide whether this change is visually observable in a running app at all (e.g. a UI,
           template, or asset change) versus purely backend/invisible (e.g. internal refactors, docs,
           tests, non-UI config). If it isn't visually testable, call `submit_visual_review` with
           verdict "skipped" and a short reason, and stop — do not start a preview.
        2. If it is visually testable, call `start_preview` to boot the app. If the documented seed
           data above doesn't cover the feature under test, you may run additional ad hoc seed
           commands yourself via your normal shell access to reach the state you need.
        3. Use your browser tools (navigate, snapshot, click, fill, hover, wait_for, resize, screenshot,
           evaluate, file_upload, drop, drag) to drive the running app against your own improvised test
           plan targeting what changed. Don't just load the homepage — exercise the actual feature. Use
           `hover` for `:hover`/`mouseenter`-triggered UI (tooltips, hover popups/cards, hover-revealed
           controls) that `click` cannot exercise — don't default to "skipped" just because the behavior
           only appears on hover.
           For click/fill/hover/single-element screenshots, call `browser_snapshot` first and copy the exact
           `element` text plus `ref` returned by that snapshot. Never invent refs, use CSS selectors as
           refs, pass an undefined target, or call click/fill/hover when the element is absent. If the element
           cannot be located, record that as a visual finding instead of repeatedly calling browser tools
           with missing arguments.
           For drag/drop-shaped features, pick the right tool for what's actually being dragged:
             - Native file drag-and-drop onto a drop zone (e.g. dragging a file so a `drop` event with
               populated `DataTransfer.files` fires): use `browser_drop` with the target element found via
               `browser_snapshot` and the absolute path(s) to drop — it synthesizes a real drag/drop via
               Playwright itself, dropping actual files backed by real bytes on disk. Only fall back to
               `browser_evaluate` (constructing a synthetic `File` + `DataTransfer` and dispatching
               `dragenter`/`dragover`/`drop` yourself, the same pattern the codebase's own RTL tests use via
               `fireEvent.drop(target, { dataTransfer: { files } })`) when the scenario needs something
               `browser_drop`'s paths/data model doesn't cover, such as inspecting an intermediate drag
               state or a custom `DataTransfer` configuration.
             - File-picker / `<input type="file">` attachment: `browser_file_upload` with the absolute
               path(s) to upload.
             - Non-file element-to-element dragging (list reordering, sliders, resizable panels):
               `browser_drag` between the start and end elements.
             - A scenario that's specifically about a literal OS-level drag of a file from the desktop
               file system into the browser (as opposed to the DOM `drop` event a page can be made to
               receive, which `browser_drop`/`browser_evaluate` both cover) is permanently unverifiable
               by any browser automation tool — it happens below the browser's event model. Call
               `submit_visual_review` with verdict "skipped" and say so plainly; do not spend retries hunting for a way around it.
           If browser automation itself appears unavailable or broken (for example click/fill/navigate
           repeatedly return tool errors despite valid snapshot refs, or the browser crashes), make at
           most two focused retries, read preview logs if useful, then call `submit_visual_review` with
           verdict "skipped" and explain the tooling blocker. Do not fall back to builds, tests, lint,
           typecheck, or direct code-only review as a substitute for visual inspection.
        4. By default, test the change at both a desktop viewport
           (#{viewport_label(DESKTOP_VIEWPORT)}) and a mobile viewport
           (#{viewport_label(MOBILE_VIEWPORT)}) via `browser_resize`, capturing screenshots at each
           with `submit_visual_artifact` and titling them clearly (e.g. "Desktop — ..." /
           "Mobile — ..."). You may skip one viewport when the issue/diff context makes it clearly
           irrelevant (a mobile-nav-only bug report, a component hidden below a desktop breakpoint,
           an admin-only desktop tool) — but if you skip a viewport, state why in your critique so it
           is an auditable judgment call, not a silent omission. `browser_resize` fully re-applies the
           viewport each time, so there's no need to reset between calls; but a resize triggers a
           layout reflow, so re-run `browser_snapshot` before the next click/fill after resizing —
           never reuse refs captured at the previous viewport size.
        5. Capture "after" screenshots of what you tested with the image-artifact submit tool so an
           operator can see the result.
        6. Call `submit_visual_review` with your verdict and critique.
        7. Always call `stop_preview` before you finish, whether or not you started one.
      TEXT
    end

    def viewport_label(viewport)
      "#{viewport[:width]}x#{viewport[:height]}"
    end

    def prior_review_context
      return "Prior visual review findings: none." if @prior_findings.empty?

      [
        "Prior visual review findings:",
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
        When finished, call the `submit_visual_review` MCP tool exposed by `syrus-mcp-sidecar` with the exact name shown in your tool list. Do not call bare `submit_visual_review` unless that exact bare name is available.
        - critique: concise Markdown describing concrete visual findings, a short note that you found no blocking issues, or the reason visual review doesn't apply.
        - verdict: "needs_work" when implementation changes are needed, "approved" when the change looks correct, "skipped" when the change isn't visually testable.

        The verdict is recorded for future workflow control but is not acted on yet.

        Do not call `ReportFindings` or any other generic findings-reporting tool — this step is only complete once `submit_visual_review` has been called.
      TEXT
    end
  end
end
