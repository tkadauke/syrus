module DesignDocs
  class AgentRunJob < PluginJob
    plugin :design_docs
    DEFAULT_TIMEOUT_SECONDS = 2.minutes.to_i
    DEFAULT_MAX_TURNS = 2
    discard_on ActiveRecord::RecordNotFound

    class << self
      attr_accessor :agent_runner
    end

    def perform(run_id)
      run = DesignDocs::DesignDocAgentRun.includes(:design_doc, :thread, :triggering_comment, :requested_by_user).find(run_id)
      provider_configured = run.requested_by_user.agent_provider_configured?(run.agent_provider)
      return unless claim(run)

      if provider_configured
        execute(run)
      else
        fail_run!(run, "Agent provider #{run.agent_provider} is not configured for #{run.requested_by_user.email_address}.")
      end
    end

    private

    def claim(run)
      started_at = Time.current
      claimed = DesignDocs::DesignDocAgentRun.where(id: run.id, status: "queued")
        .update_all(status: "running", started_at:)
      return false unless claimed == 1

      run.status = "running"
      run.started_at = started_at
      true
    end

    def execute(run)
      broadcast(run)
      agent = Agent.find_or_create_for!(run)
      result = AgentProviders.run_one_shot(
        provider: run.agent_provider,
        user: run.requested_by_user,
        runner: self.class.agent_runner || Syrus::Host::RunJob.agent_runner,
        scope: "design-doc-agent-runs",
        prompt: DesignDocs::AgentRunPrompt.new(run: run).to_s,
        log_sink: ->(*, **) { },
        timeout: DEFAULT_TIMEOUT_SECONDS,
        max_turns: DEFAULT_MAX_TURNS,
        agent: agent
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
