module McpToolPayloads
  # Shared workflow/run/log payload builders used by chat MCP read tools and future insight jobs.
  # Extend this module into a class's singleton to get all helpers as class methods.
  module WorkflowPayload
    # Compact index entry used in list_job_workflows and read_job's workflow index.
    def workflow_index_payload(workflow)
      runs = workflow_step_runs(workflow)
      latest_run = latest_run_for(runs)
      {
        id: workflow.id,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state,
        summary: text_snippet(workflow.artifact("summary").presence || latest_run&.agent_summary, 300),
        step_count: workflow.steps.size,
        run_count: runs.size,
        started_at: workflow.started_at&.iso8601,
        finished_at: workflow.finished_at&.iso8601
      }
    end

    # Brief summary payload used in read_job's latest_workflow field.
    def workflow_summary_payload(workflow)
      return nil unless workflow

      latest_run = workflow.runs.last
      {
        id: workflow.id,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state,
        agent_provider: workflow.agent_provider,
        summary: workflow.artifact("summary").presence || latest_run&.agent_summary,
        created_at: workflow.created_at&.iso8601,
        finished_at: workflow.finished_at&.iso8601
      }
    end

    # One chunk row from a Run's job_logs, used by read_run_transcript.
    def run_log_payload(log)
      {
        sequence: log.sequence,
        kind: log.kind,
        chunk: log.chunk
      }
    end

    # All runs across every step of a workflow.
    def workflow_step_runs(workflow)
      workflow.steps.flat_map(&:runs)
    end

    # The most recently created run in a flat runs list.
    def latest_run_for(runs)
      runs.max_by { |run| [ run.created_at || Time.at(0), run.id || 0 ] }
    end

    # Truncate text to a character count, returning nil if blank after truncation.
    def text_snippet(text, length)
      text.to_s.each_char.first(length).join.presence
    end
  end
end
