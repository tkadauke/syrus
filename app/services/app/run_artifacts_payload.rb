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
        page_rows = logs_scope.offset((page - 1) * per).limit(per)
          .pluck(:id, :sequence, :kind, :chunk, :tool_metadata, :created_at)
          .reverse
        rows = include_tool_pair_context(logs_scope, page_rows)

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

      # A row page may cut between a structured tool call and its result. Add
      # the matching row as render context without changing pagination counts;
      # otherwise either side of the boundary becomes an orphaned SYSTEM row
      # or a permanently-running tool. This is deliberately id-based because
      # parallel calls make adjacency unreliable.
      def include_tool_pair_context(logs_scope, page_rows)
        page_ids = page_rows.filter_map { |row| tool_use_id(row) }.to_set
        return page_rows if page_ids.empty?

        kinds_by_id = page_rows.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |row, kinds|
          id = tool_use_id(row)
          kinds[id] << row[2] if id
        end
        missing_call_ids = page_ids.reject { |id| kinds_by_id[id].include?("tool_call") }.to_set
        missing_result_ids = page_ids.reject { |id| kinds_by_id[id].include?("tool_result") }.to_set
        return page_rows if missing_call_ids.empty? && missing_result_ids.empty?

        first_sequence = page_rows.first[1]
        last_sequence = page_rows.last[1]
        context_rows = matching_context_rows(logs_scope.where("sequence < ?", first_sequence), missing_call_ids, "tool_call")
        context_rows.concat(matching_context_rows(logs_scope.where("sequence > ?", last_sequence), missing_result_ids, "tool_result"))

        (page_rows + context_rows).sort_by { |row| [row[1], row[0]] }
      end

      def matching_context_rows(scope, missing_ids, kind)
        return [] if missing_ids.empty?

        rows = []
        scope.where(kind: kind).find_each do |log|
          id = log.tool_metadata&.fetch("tool_use_id", nil)
          next unless missing_ids.delete?(id)

          rows << [log.id, log.sequence, log.kind, log.chunk, log.tool_metadata, log.created_at]
          break if missing_ids.empty?
        end
        rows
      end

      def tool_use_id(row)
        row[4]&.fetch("tool_use_id", nil)
      end

      def serialize_log(row)
        id, sequence, kind, chunk, tool_metadata, created_at = row
        metadata = ToolPayloadRedactor.redact(tool_metadata || {})
        {
          id: id,
          sequence: sequence,
          kind: kind,
          chunk: chunk,
          tool_name: metadata["tool_name"],
          tool_input: metadata["tool_input"],
          tool_use_id: metadata["tool_use_id"],
          tool_result_content: metadata["tool_result_content"],
          tool_result_error: metadata["tool_result_error"],
          created_at: created_at&.iso8601
        }
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
