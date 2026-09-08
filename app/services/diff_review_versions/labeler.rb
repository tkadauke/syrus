module DiffReviewVersions
  class Labeler
    class Base
      def initialize(job:, workflow:, run:, trigger_kind:)
        @job = job
        @workflow = workflow
        @run = run
        @trigger_kind = trigger_kind.to_s
      end

      def label
        trigger_kind.humanize.presence || "Diff version"
      end

      private

      attr_reader :job, :workflow, :run, :trigger_kind

      def next_number_for(kind)
        job.diff_review_versions.where(trigger_kind: kind).count + 1
      end
    end

    class Initial < Base
      def label = "Initial implementation"
    end

    class ChatFeedback < Base
      def label = "Chat feedback ##{next_number_for('chat_feedback')}"
    end

    class PrComment < Base
      def label = "PR comment follow-up"
    end

    class ExternalPrFeedback < Base
      def label = "PR comment follow-up"
    end

    class Retry < Base
      def label = "Retry"
    end

    class Manual < Base
      def label = "Manual run"
    end

    class ManualAgenticRun < Base
      def label = "Manual run"
    end

    class Rebase < Base
      def label = "Rebase"
    end

    class CodingHandoff < Base
      def label = "Coding handoff"
    end

    class LocalModeHandoff < Base
      def label = "Local mode handoff"
    end

    class CiFailure < Base
      def label = "CI repair"
    end

    class Skill < Base
      def label = "Skill run"
    end

    MAPPING = {
      "initial" => Initial,
      "chat_feedback" => ChatFeedback,
      "pr_comment" => PrComment,
      "external_pr_feedback" => ExternalPrFeedback,
      "retry" => Retry,
      "manual" => Manual,
      "manual_agentic_run" => ManualAgenticRun,
      "rebase" => Rebase,
      "coding_handoff" => CodingHandoff,
      "local_mode_handoff" => LocalModeHandoff,
      "ci_failure" => CiFailure,
      "skill" => Skill
    }.freeze

    def self.call(job:, workflow: nil, run: nil, trigger_kind: nil)
      resolved_trigger_kind = trigger_kind.to_s.presence || workflow&.trigger_kind || run&.trigger_kind
      MAPPING.fetch(resolved_trigger_kind.to_s, Base)
             .new(job: job, workflow: workflow, run: run, trigger_kind: resolved_trigger_kind)
             .label
    end
  end
end
