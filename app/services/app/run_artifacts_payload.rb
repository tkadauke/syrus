module App
  class RunArtifactsPayload
    DEFAULT_LOGS_PER_PAGE = 100
    MAX_LOGS_PER_PAGE = 200
    ARTIFACTS = {
      "transcript" => "App::RunArtifactsPayload::Transcript",
      "agent_diff" => "App::RunArtifactsPayload::AgentDiff",
      "step_agent_diff" => "App::RunArtifactsPayload::StepAgentDiff"
    }.freeze

    def self.build(run:, artifact: "transcript", page: 1, per: DEFAULT_LOGS_PER_PAGE)
      artifact_class = ARTIFACTS.fetch(artifact.to_s, ARTIFACTS.fetch("transcript")).constantize
      artifact_class.new(run: run, page: page.presence || 1, per: per.presence || DEFAULT_LOGS_PER_PAGE).build
    end

    class Base
      def initialize(run:, page:, per:)
        @run = run
        @page = [page.to_i, 1].max
        @per = [[per.to_i, 1].max, MAX_LOGS_PER_PAGE].min
      end

      def build
        {
          job_id: run.job_id,
          workflow_id: run.step&.workflow_id,
          run_id: run.id,
          diff_review_version_id: diff_review_version&.id,
          base_ref: run.base_sha,
          head_ref: run.head_sha
        }.merge(artifact_payload)
      end

      private

      attr_reader :run, :page, :per

      def diff_review_version
        DiffReviewVersion.where(job_id: run.job_id, run_id: run.id).latest_first.first
      end
    end

    class Transcript < Base
      private

      def artifact_payload
        logs_scope = run.job_logs.reorder(sequence: :desc, id: :desc)
        logs_count = logs_scope.count
        rows = logs_scope.offset((page - 1) * per).limit(per)
          .pluck(:id, :sequence, :kind, :chunk, :created_at)
          .reverse

        {
          artifact: "transcript",
          logs_count: logs_count,
          logs_page: page,
          logs_per_page: per,
          logs_total_pages: (logs_count.to_f / per).ceil,
          logs_has_older: page * per < logs_count,
          logs: rows.map { |row| serialize_log(row) }
        }
      end

      def serialize_log(row)
        id, sequence, kind, chunk, created_at = row
        { id: id, sequence: sequence, kind: kind, chunk: chunk, created_at: created_at&.iso8601 }
      end
    end

    class AgentDiff < Base
      private

      def artifact_payload
        diff = Run.where(id: run.id).pick(:agent_diff)
        { artifact: "agent_diff", agent_diff: diff, agent_diff_bytes: diff&.bytesize || 0 }
      end
    end

    class StepAgentDiff < Base
      private

      def artifact_payload
        diff = Run.where(id: run.id).pick(:step_agent_diff)
        { artifact: "step_agent_diff", step_agent_diff: diff, step_agent_diff_bytes: diff&.bytesize || 0 }
      end
    end
  end
end
