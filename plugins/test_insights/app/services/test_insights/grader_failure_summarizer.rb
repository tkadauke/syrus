module TestInsights
  # Answers "what actually failed?" for a failed grader Step, from the test
  # results this plugin already ingested for that grader's run.
  #
  # The repair agent that runs after a failed grade iteration used to learn
  # this from the grader's log, which is the wrong shape for the question: a
  # failing suite writes tens of kilobytes of prose with the failures scattered
  # through it, and the excerpt core can afford to keep inline routinely omits
  # most of them. One observed landing iteration recorded nine failing
  # examples and showed the agent two of them -- including hiding three
  # failures in the very file the agent then edited.
  #
  # These records are exact, so this summary is complete by construction.
  class GraderFailureSummarizer
    include Syrus::Plugin::GraderFailureSummarizer

    FAILED_STATUSES = %w[failed error].freeze
    FILE_LIMIT = 15
    EXAMPLES_PER_FILE = 5
    MESSAGE_BYTES = 180

    class << self
      def summarize_grader_failure(grader_step:, run:, grader_name:)
        return [] if run.nil?

        test_run = test_run_for(run: run, grader_name: grader_name)
        return [] if test_run.nil?

        failures = TestCase
          .where(test_run_id: test_run.id, status: FAILED_STATUSES)
          .order(:file_path, :name)
          .to_a
        return [] if failures.empty?

        [ headline(test_run, failures) ] + grouped_lines(failures)
      rescue StandardError => e
        # The contract says this must not raise: a summarizer having a bad day
        # must not cost the repair agent the rest of its context.
        Rails.logger.warn("[TestInsights] grader failure summary failed: #{e.class}: #{e.message}")
        []
      end

      private

      # Prefer the TestRun recorded for this exact grader. A single Run can
      # carry results for more than one grader, so matching on name keeps a
      # react-tests summary out of an rspec failure and vice versa. Fall back
      # to the run's only TestRun when the names do not line up, which is
      # better than saying nothing.
      def test_run_for(run:, grader_name:)
        scope = TestRun.for_run(run)
        by_name = scope.where(grader_name: grader_name).order(:id).last
        return by_name if by_name

        scope.count == 1 ? scope.first : nil
      end

      def headline(test_run, failures)
        total = test_run.total_count.to_i
        counted = total.positive? ? "#{failures.size} of #{total} examples failed" : "#{failures.size} example(s) failed"
        "#{counted} in this grader run. Every failure is listed below."
      end

      def grouped_lines(failures)
        by_file = failures.group_by { |test_case| test_case.file_path.presence || "(unknown file)" }
        lines = []

        by_file.first(FILE_LIMIT).each do |file_path, cases|
          lines << "#{normalize_path(file_path)} (#{cases.size} failing)"
          lines.concat(example_lines(cases))
        end

        remaining_files = by_file.size - FILE_LIMIT
        lines << "... and #{remaining_files} more file(s) with failures; see the full log." if remaining_files.positive?
        lines
      end

      def example_lines(cases)
        lines = []
        cases.first(EXAMPLES_PER_FILE).each do |test_case|
          lines << "  #{test_case.name}"
          message = first_message_line(test_case.failure_message)
          lines << "    #{message}" if message.present?
        end

        hidden = cases.size - EXAMPLES_PER_FILE
        lines << "  ... and #{hidden} more in this file." if hidden.positive?
        lines
      end

      # The first line is the assertion itself; what follows is usually the
      # diff and backtrace, which belong in the log rather than the prompt.
      def first_message_line(message)
        line = message.to_s.lines.find { |candidate| candidate.strip.present? }
        return nil if line.blank?

        line.strip.safe_byteslice(0, MESSAGE_BYTES)
      end

      # Ingested paths arrive as "./spec/foo_spec.rb"; the agent works with
      # repo-relative paths.
      def normalize_path(file_path)
        file_path.to_s.delete_prefix("./")
      end
    end
  end
end
