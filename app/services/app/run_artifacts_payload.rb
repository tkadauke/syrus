module App
  class RunArtifactsPayload
    DEFAULT_LOGS_PER_PAGE = 100
    MAX_LOGS_PER_PAGE = 200
    MAX_DIFF_BYTES = 2.megabytes
    ARTIFACTS = {
      "transcript" => "App::RunArtifactsPayload::Transcript",
      "agent_diff" => "App::RunArtifactsPayload::AgentDiff",
      "step_agent_diff" => "App::RunArtifactsPayload::StepAgentDiff"
    }.freeze

    def self.build(run:, artifact: "transcript", page: 1, per: DEFAULT_LOGS_PER_PAGE, after_sequence: nil, full: false)
      artifact_class = ARTIFACTS.fetch(artifact.to_s, ARTIFACTS.fetch("transcript")).constantize
      artifact_class.new(
        run: run,
        page: page.presence || 1,
        per: per.presence || DEFAULT_LOGS_PER_PAGE,
        after_sequence: after_sequence,
        full: ActiveModel::Type::Boolean.new.cast(full)
      ).build
    end

    class Base
      def initialize(run:, page:, per:, after_sequence: nil, full: false)
        @run = run
        @page = [page.to_i, 1].max
        @per = [[per.to_i, 1].max, MAX_LOGS_PER_PAGE].min
        @after_sequence = after_sequence.presence&.to_i
        @full = full
      end

      def build
        {
          job_id: run.job_id,
          workflow_id: run.step&.workflow_id,
          run_id: run.id,
          run_state: run.state,
          complete: run.job.closed?,
          diff_review_version_id: diff_review_version&.id,
          base_ref: run.base_sha,
          head_ref: run.head_sha
        }.merge(artifact_payload)
      end

      private

      attr_reader :run, :page, :per, :after_sequence, :full

      def diff_review_version
        DiffReviewVersion.where(job_id: run.job_id, run_id: run.id).latest_first.first
      end
    end

    class Transcript < Base
      private

      def artifact_payload
        logs_scope = run.job_logs.reorder(sequence: :desc, id: :desc)
        logs_count = logs_scope.count
        return delta_payload(logs_scope, logs_count) unless after_sequence.nil?

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
          logs_max_sequence: logs_scope.maximum(:sequence),
          logs: rows.map { |row| serialize_log(row) }
        }
      end

      def delta_payload(logs_scope, logs_count)
        rows = logs_scope.where("sequence > ?", after_sequence).reorder(sequence: :asc, id: :asc)
          .limit(per).pluck(:id, :sequence, :kind, :chunk, :tool_metadata, :created_at)
        max_sequence = logs_scope.maximum(:sequence)

        {
          artifact: "transcript",
          logs_count: logs_count,
          logs_page: 1,
          logs_per_page: per,
          logs_total_pages: (logs_count.to_f / per).ceil,
          logs_has_older: false,
          logs_max_sequence: rows.last&.fetch(1, nil) || after_sequence,
          logs_has_newer: rows.last&.fetch(1, nil).to_i < max_sequence.to_i,
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

    class Diff < Base
      private

      def diff_payload(key)
        bytes, diff = if full
          value = Run.where(id: run.id).pick(key)
          [ value&.bytesize || 0, value ]
        else
          Run.where(id: run.id).pick(
            Arel.sql(diff_bytes_expression(key)),
            Arel.sql("SUBSTRING(#{key}, 1, #{MAX_DIFF_BYTES})")
          )
        end
        bytes ||= 0
        diff = diff&.safe_byteslice(0, MAX_DIFF_BYTES) unless full
        { artifact: key, key.to_sym => diff, "#{key}_bytes".to_sym => bytes,
          "#{key}_truncated".to_sym => !full && bytes > MAX_DIFF_BYTES }
      end

      def diff_bytes_expression(key)
        if Run.connection.adapter_name.downcase.include?("mysql")
          "OCTET_LENGTH(#{key})"
        else
          "LENGTH(CAST(#{key} AS BLOB))"
        end
      end
    end

    class AgentDiff < Diff
      private

      def artifact_payload
        diff_payload("agent_diff")
      end
    end

    class StepAgentDiff < Diff
      private

      def artifact_payload
        diff_payload("step_agent_diff")
      end
    end
  end
end
