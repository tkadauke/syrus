module DesignDocs
  class AgentRunJob < ApplicationJob
    DEFAULT_TIMEOUT_SECONDS = 2.minutes.to_i
    DEFAULT_MAX_TURNS = 2

    queue_as :chat
    discard_on ActiveRecord::RecordNotFound

    class << self
      attr_accessor :agent_runner
    end

    limits_concurrency to: 1, group: "design_doc_thread_agent", key: ->(run_id) {
      run = DesignDocs::DesignDocAgentRun.find_by(id: run_id)
      run ? "design_doc_thread:#{run.design_doc_thread_id}" : "design_doc_agent_run:#{run_id}"
    }, duration: 15.minutes

    def perform(run_id)
      run = DesignDocs::DesignDocAgentRun.includes(:design_doc, :thread, :triggering_comment, :requested_by_user).find(run_id)
      return unless run.status == "queued"

      if run.requested_by_user.agent_provider_configured?(run.agent_provider)
        execute(run)
      else
        fail_run!(run, "Agent provider #{run.agent_provider} is not configured for #{run.requested_by_user.email_address}.")
      end
    end

    private

    def execute(run)
      run.update!(status: "running", started_at: Time.current)
      broadcast(run)
      result = AgentProviders.run_one_shot(
        provider: run.agent_provider,
        user: run.requested_by_user,
        runner: self.class.agent_runner || RunJob.agent_runner,
        scope: "design-doc-agent-runs",
        prompt: DesignDocs::AgentRunPrompt.new(run: run).to_s,
        log_sink: ->(*, **) { },
        timeout: DEFAULT_TIMEOUT_SECONDS,
        max_turns: DEFAULT_MAX_TURNS
      )

      return fail_run!(run, "timed out after #{DEFAULT_TIMEOUT_SECONDS}s") if result.timed_out
      return fail_run!(run, "agent reported #{result.outcome || 'error'}") if result.is_error
      return fail_run!(run, "agent exited #{result.exit_status}") unless result.success?
      return fail_run!(run, "empty response") if result.final_text.blank?

      capture_session!(run, result)
      summary, output_payload = DesignDocs::ApplyAgentRunOutput.call(run: run, raw_output: result.final_text)
      run.update!(status: "succeeded", finished_at: Time.current, result_summary: summary, output_payload: output_payload)
      broadcast(run)
    rescue StandardError => e
      Rails.logger.warn("[DesignDocs::AgentRunJob] run_id=#{run&.id} #{e.class}: #{e.message}")
      fail_run!(run, "#{e.class}: #{e.message}") if run
    end

    def capture_session!(run, result)
      return if result.session_id.blank?

      run.create_provider_session!(
        provider: run.agent_provider,
        session_id: result.session_id,
        transcript_jsonl: result.transcript_jsonl.presence
      )
    end

    def fail_run!(run, message)
      run.update!(status: "failed", finished_at: Time.current, error_message: message)
      broadcast(run)
    end

    def broadcast(run)
      DesignDocs::CommentBroadcaster.call(design_doc: run.design_doc.reload, changed: [ "agent_runs", "comments", "suggestions" ])
    end
  end
end
