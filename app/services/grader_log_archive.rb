# Rebuilds a grader Step's complete command output and writes it into a
# workspace, so the repair agent that runs after a failed grade iteration can
# read the whole log instead of a truncated excerpt.
#
# Why this exists rather than just pointing at the grader's own log file: a
# grader writes its output to `.syrus/grade-output/...` inside the workspace
# it ran in, and graders fan out across workers, so that file is usually on a
# different machine than the repair step. The copy that survives is the chunk
# stream the grader published while running (JobLog, kind "grade_log"), which
# is complete and machine-independent. That stream is the source of truth
# here; the manifest written to workflow artifacts is only an index into it.
#
# A grader that died before producing any output has no chunks at all. That is
# a different situation from "the log was long", and it is recorded as an
# explicit unavailable_reason rather than as an empty log, so the repair agent
# is never handed a blank section with no explanation.
class GraderLogArchive
  MANIFEST_ARTIFACT_KEY = "grade_log_manifest".freeze
  RELATIVE_ROOT = ".syrus/grade-logs".freeze

  # The prompt carries a preview only. It exists to tell the agent which log
  # is worth opening, not to stand in for the log.
  PREVIEW_LINE_LIMIT = 40
  PREVIEW_TAIL_BYTES = 2048
  # The manifest rides in workflow.artifacts, a mediumtext column that is
  # already well over a megabyte on a busy workflow, so the preview is capped
  # even when the failure lines are long. The log itself is never truncated --
  # it is on disk, and the entry says where.
  PREVIEW_MAX_BYTES = 4096

  # Lines worth surfacing in a preview: test-runner failure headers and
  # summaries. Deliberately broad -- a preview that misses the interesting
  # line costs the agent one file read, while a narrow pattern that matches
  # nothing falls back to the tail anyway.
  FAILURE_LINE = /
    ^(?:
      rspec\s+\.\/ |
      \s+\d+\)\s |
      Failures: |
      Failed\ examples: |
      \s*\d+\s+examples?,\s+\d+\s+failure |
      .*\b(?:FAILED|FAIL|Error:|error:|Traceback|AssertionError)\b
    )
  /x

  WRITE_CHUNK_ROWS = 500

  def self.sanitize_name(name)
    cleaned = name.to_s.strip.gsub(%r{[^A-Za-z0-9._-]+}, "-").gsub(/\A-+|-+\z/, "")
    cleaned.presence || "unnamed-grader"
  end

  def self.relative_path_for(iteration:, name:)
    "#{RELATIVE_ROOT}/iteration-#{iteration}/#{sanitize_name(name)}.log"
  end

  # A plugin-authored summary is also capped, for the same reason the preview
  # is: it rides in the artifacts column. A summarizer that needs more room
  # than this is writing a second copy of the log, which is not its job.
  SUMMARY_LINE_LIMIT = 60
  SUMMARY_MAX_BYTES = 8192

  # Writes one log per grader Step and returns the manifest entries.
  #
  # `failure_summaries` maps a grader Step id to the lines a
  # :grader_failure_summarizer plugin produced for it. Those lines are carried
  # on the entry verbatim -- core does not parse or reformat them, because what
  # a test failure is belongs to the plugin that owns test results.
  def self.write_all!(grader_steps:, iteration:, workspace_path:, failure_summaries: {})
    summaries = (failure_summaries || {}).to_h
    Array(grader_steps).map do |grader_step|
      new(
        step: grader_step,
        iteration: iteration,
        workspace_path: workspace_path,
        failure_summary: summaries[grader_step.id]
      ).write!
    end
  end

  # Recreates the files described by `entries` in another workspace. Used by
  # the repair step, which may run on a different worker than the grader and
  # the collect step did, so it cannot assume the files are already present.
  # Entries whose log was never produced are skipped: there is nothing to
  # write, and the manifest already says why.
  def self.materialize!(entries:, workspace_path:)
    Array(entries).filter_map do |entry|
      entry = entry.to_h.with_indifferent_access
      next if entry[:grader_step_id].blank?
      next if entry[:unavailable_reason].present?

      step = Step.find_by(id: entry[:grader_step_id])
      next if step.nil?

      new(
        step: step,
        iteration: entry[:iteration],
        workspace_path: workspace_path,
        relative_path: entry[:relative_path]
      ).write!
    end
  end

  def initialize(step:, iteration:, workspace_path:, relative_path: nil, failure_summary: nil)
    @step = step
    @iteration = iteration
    @workspace_path = Pathname.new(workspace_path.to_s)
    @relative_path = relative_path
    @failure_summary = failure_summary
  end

  def write!
    chunks = log_chunks
    return unavailable_entry if chunks.empty?

    absolute = @workspace_path.join(relative_path)
    FileUtils.mkdir_p(absolute.dirname)

    preview_builder = PreviewBuilder.new
    bytes = 0
    File.open(absolute, "wb") do |file|
      chunks.each_slice(WRITE_CHUNK_ROWS) do |slice|
        text = slice.join
        file.write(text)
        bytes += text.bytesize
        preview_builder.consume(text)
      end
    end

    entry(bytes: bytes, preview: preview_builder.to_s)
  end

  private

  attr_reader :step, :iteration

  def relative_path
    @relative_path.presence || self.class.relative_path_for(iteration: iteration, name: grader_name)
  end

  def grader_name
    details["name"].presence || "unnamed-grader"
  end

  def details
    (step.details || {})
  end

  # Ordered oldest-first across every Run of this Step. A retried grader Step
  # has more than one Run, and the later Run is the one whose failure is being
  # repaired, so Run order matters as well as sequence within a Run.
  def log_chunks
    run_ids = step.runs.order(:id).pluck(:id)
    return [] if run_ids.empty?

    JobLog
      .where(run_id: run_ids, kind: "grade_log")
      .order(:run_id, :sequence, :id)
      .pluck(:chunk)
      .compact
  end

  def entry(bytes:, preview:)
    {
      "grader_step_id" => step.id,
      "name" => grader_name,
      "iteration" => iteration,
      "required" => details["required"],
      "status" => step.state == "succeeded" ? "passed" : "failed",
      "command" => details["command"],
      "exit_code" => details["exit_code"],
      "timed_out" => details["timed_out"],
      "relative_path" => relative_path,
      "bytes" => bytes,
      "preview" => preview,
      "failure_summary" => capped_failure_summary
    }.compact
  end

  # Kept separate from `preview`, not merged into it: the summary is an exact
  # account from the plugin that ingested the results, while the preview is a
  # best-effort guess scraped out of log text. The prompt prefers the former
  # and falls back to the latter, so conflating them would lose that ordering.
  def capped_failure_summary
    lines = Array(@failure_summary).map { |line| line.to_s.chomp }.reject(&:empty?)
    return nil if lines.empty?

    lines = lines.first(SUMMARY_LINE_LIMIT)
    kept = []
    bytes = 0
    lines.each do |line|
      bytes += line.bytesize + 1
      break if bytes > SUMMARY_MAX_BYTES

      kept << line
    end
    kept.presence
  end

  # No chunks were ever published for this grader. Say which case it is
  # instead of rendering an empty log: a grader that never started reads very
  # differently to the agent than one that ran and printed nothing.
  def unavailable_entry
    reason =
      if step.state.in?(%w[cancelled queued])
        "the grader Step ended as #{step.state} without running its command, so no output was produced"
      elsif details["exit_code"].blank? && step.started_at.blank?
        "the grader Step never started, so no output was produced"
      elsif details["exit_code"].blank?
        "the grader process produced no output before the Step ended (its worker most likely died mid-run)"
      else
        "the grader exited #{details['exit_code']} without writing any output"
      end

    {
      "grader_step_id" => step.id,
      "name" => grader_name,
      "iteration" => iteration,
      "required" => details["required"],
      "status" => step.state == "succeeded" ? "passed" : "failed",
      "command" => details["command"],
      "exit_code" => details["exit_code"],
      "timed_out" => details["timed_out"],
      "bytes" => 0,
      "unavailable_reason" => reason,
      "failure_summary" => capped_failure_summary
    }.compact
  end

  # Collects failure-looking lines as the log streams past, and keeps a
  # rolling tail so a log with no recognizable failure line still previews as
  # something useful. Streaming matters: a grader log can be tens of
  # megabytes, and the whole point is not to hold it in memory.
  class PreviewBuilder
    def initialize
      @failure_lines = []
      @tail = +""
      @partial = +""
    end

    def consume(text)
      buffer = @partial + text
      lines = buffer.lines
      @partial = lines.last.to_s.end_with?("\n") ? +"" : (lines.pop.to_s.dup)

      lines.each do |line|
        next if @failure_lines.size >= PREVIEW_LINE_LIMIT
        @failure_lines << line.chomp if line.match?(FAILURE_LINE)
      end

      @tail << text
      return if @tail.bytesize <= PREVIEW_TAIL_BYTES

      @tail = @tail.byteslice(-PREVIEW_TAIL_BYTES, PREVIEW_TAIL_BYTES).to_s.dup
    end

    def to_s
      flush_partial
      return failure_preview if @failure_lines.any?

      tail_preview
    end

    private

    def flush_partial
      return if @partial.empty?
      if @failure_lines.size < PREVIEW_LINE_LIMIT && @partial.match?(FAILURE_LINE)
        @failure_lines << @partial.chomp
      end
      @partial = +""
    end

    def failure_preview
      scrub(@failure_lines.join("\n"))
    end

    def tail_preview
      scrub(@tail.to_s)
    end

    def scrub(text)
      clean = text.dup.force_encoding(Encoding::UTF_8)
                  .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
      return clean if clean.bytesize <= PREVIEW_MAX_BYTES

      clean.byteslice(0, PREVIEW_MAX_BYTES).to_s
           .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    end
  end
end
