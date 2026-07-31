module SyrusMcp
  class LiveState
    RECENT_WORKFLOW_LIMIT = 3
    RELATED_CHAT_LIMIT = 5
    RECENT_MESSAGE_LIMIT = 3

    def initialize(run)
      @run = run
      @job = run.job
      @workflow = run.workflow || @job.latest_workflow
      @step = run.step
    end

    def as_json(detail: "compact")
      compact = detail.to_s != "full"

      {
        generated_at: Time.current.iso8601,
        detail: compact ? "compact" : "full",
        links: top_level_links,
        job: job_payload,
        workflow: workflow_payload(@workflow, compact: compact),
        run: run_payload(@run, compact: compact),
        worker_health_correlation: WorkerHealthRunCorrelation.for_run(
          @run,
          sample_limit: compact ? 0 : WorkerHealthRunCorrelation::SAMPLE_LIMIT
        ),
        queue: queue_payload,
        chat: chat_payload(compact: compact)
      }.tap do |payload|
        payload[:recent_workflows] = recent_workflows_payload(compact: compact) unless compact
      end
    end

    private

    attr_reader :run, :job, :workflow, :step

    def top_level_links
      {
        app_job: "/jobs/#{job.id}",
        api_job: "/api/v1/admin/jobs/#{job.id}",
        api_workflow: workflow && "/api/v1/admin/workflows/#{workflow.id}",
        api_run_transcript: "/api/v1/admin/runs/#{run.id}/transcript",
        api_queue: "/api/v1/admin/queue"
      }.compact
    end

    def job_payload
      {
        id: job.id,
        slug: job.slug,
        kind: job.kind,
        state: job.state,
        repository: job.repository.slug,
        issue: issue_payload,
        pull_request: pull_request_payload,
        branch_name: job.branch_name,
        priority: job.priority,
        agent_provider: job.workflow_agent_provider,
        job_provider_setting: job.job_provider_setting,
        validity: job.validity,
        closure_reason: job.closure_reason,
        created_at: timestamp(job.created_at),
        updated_at: timestamp(job.updated_at),
        started_at: timestamp(job.started_at),
        finished_at: timestamp(job.finished_at)
      }
    end

    def issue_payload
      return nil if job.issue_number.blank? && job.issue_title.blank?

      {
        number: job.issue_number,
        title: job.issue_title,
        url: job.issue_number && "https://github.com/#{job.repository.slug}/issues/#{job.issue_number}"
      }.compact
    end

    def pull_request_payload
      number = job.pr_number || job.external_pr_number
      return nil unless number

      {
        number: number,
        internal_number: job.pr_number,
        external_number: job.external_pr_number,
        mergeable: job.pr_mergeable,
        mergeable_checked_at: timestamp(job.pr_mergeable_checked_at),
        url: "https://github.com/#{job.repository.slug}/pull/#{number}"
      }.compact
    end

    def workflow_payload(candidate, compact:)
      return nil unless candidate

      payload = {
        id: candidate.id,
        trigger_kind: candidate.trigger_kind,
        state: candidate.state,
        agent_provider: candidate.agent_provider,
        current: candidate.id == workflow&.id,
        failure_count: candidate.failure_count,
        summary: candidate.artifact("summary").presence || latest_run_for(candidate)&.agent_summary,
        active_step: step_payload(active_step_for(candidate), compact: true),
        created_at: timestamp(candidate.created_at),
        started_at: timestamp(candidate.started_at),
        finished_at: timestamp(candidate.finished_at),
        updated_at: timestamp(candidate.updated_at),
        links: {
          api: "/api/v1/admin/workflows/#{candidate.id}",
          app_job: "/jobs/#{job.id}?tab=workflows"
        }
      }
      payload[:steps] = candidate.steps.order(:position).map { |s| step_payload(s, compact: false) } unless compact
      payload
    end

    def step_payload(candidate, compact:)
      return nil unless candidate

      payload = {
        id: candidate.id,
        kind: candidate.kind,
        position: candidate.position,
        iteration: candidate.iteration,
        state: candidate.state,
        started_at: timestamp(candidate.started_at),
        finished_at: timestamp(candidate.finished_at)
      }
      payload[:runs] = candidate.runs.order(:created_at).map { |r| run_payload(r, compact: true) } unless compact
      payload
    end

    def run_payload(candidate, compact:)
      return nil unless candidate

      payload = {
        id: candidate.id,
        state: candidate.state,
        trigger_kind: candidate.trigger_kind,
        agent_provider: candidate.agent_provider,
        current: candidate.id == run.id,
        step_id: candidate.step_id,
        workflow_id: candidate.workflow_id,
        agent_outcome: candidate.agent_outcome,
        agent_turns: candidate.agent_turns,
        head_sha: candidate.head_sha,
        last_heartbeat_at: timestamp(candidate.last_heartbeat_at),
        created_at: timestamp(candidate.created_at),
        started_at: timestamp(candidate.started_at),
        finished_at: timestamp(candidate.finished_at),
        links: {
          transcript: "/api/v1/admin/runs/#{candidate.id}/transcript",
          job: "/api/v1/admin/jobs/#{candidate.job_id}"
        }
      }
      unless compact
        payload[:agent_summary] = candidate.agent_summary
        payload[:agent_diff_bytes] = candidate.agent_diff&.bytesize || 0
        payload[:job_log_count] = candidate.job_logs.count
      end
      payload
    end

    def queue_payload
      active_runs = job.runs.active.order(:created_at).map do |candidate|
        {
          id: candidate.id,
          state: candidate.state,
          workflow_id: candidate.workflow_id,
          step_id: candidate.step_id,
          trigger_kind: candidate.trigger_kind,
          created_at: timestamp(candidate.created_at),
          last_heartbeat_at: timestamp(candidate.last_heartbeat_at)
        }
      end

      {
        active_runs_for_job: active_runs,
        solid_queue: solid_queue_payload
      }
    end

    def solid_queue_payload
      return unavailable_queue_payload("SolidQueue is not loaded") unless defined?(SolidQueue::Job)

      jobs = SolidQueue::Job.where(class_name: "RunJob").order(created_at: :desc).limit(100).to_a
      matching = jobs.select { |queue_job| queue_job_run_id(queue_job) == run.id }
      {
        run_job_entries: matching.map { |queue_job| solid_queue_job_payload(queue_job) },
        sampled_run_job_count: jobs.size,
        note: "Scans the latest 100 RunJob rows for the current run id."
      }
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
      unavailable_queue_payload("#{e.class}: #{e.message}")
    end

    def unavailable_queue_payload(reason)
      { unavailable: true, reason: reason }
    end

    def solid_queue_job_payload(queue_job)
      {
        id: queue_job.id,
        queue_name: queue_job.queue_name,
        priority: queue_job.priority,
        created_at: timestamp(queue_job.created_at),
        scheduled_at: timestamp(queue_job.scheduled_at),
        finished_at: timestamp(queue_job.finished_at)
      }
    end

    def queue_job_run_id(queue_job)
      arguments = queue_job.arguments
      (arguments&.dig("arguments") || arguments&.dig(:arguments))&.first
    end

    def chat_payload(compact:)
      chats = related_chats
      {
        related_count: chats.size,
        sessions: chats.map { |chat| chat_session_payload(chat, compact: compact) },
        note: chats.empty? ? "No chat sessions are attached to this job or repository." : nil
      }.compact
    end

    def related_chats
      ChatSession
        .joins(:chat_attachments)
        .where(chat_sessions: { user_id: job.user_id })
        .where(
          "(chat_attachments.attachable_type = :job_type AND chat_attachments.attachable_id = :job_id) OR " \
          "(chat_attachments.attachable_type = :repository_type AND chat_attachments.attachable_id = :repository_id)",
          job_type: "Job",
          job_id: job.id,
          repository_type: "Repository",
          repository_id: job.repository_id
        )
        .distinct
        .order(Arel.sql("COALESCE(chat_sessions.last_message_at, chat_sessions.updated_at, chat_sessions.created_at) DESC"))
        .limit(RELATED_CHAT_LIMIT)
    end

    def chat_session_payload(chat, compact:)
      payload = {
        id: chat.id,
        title: chat.title,
        repository: chat.repository&.slug,
        message_count: chat.messages.count,
        pending_actions_count: chat.pending_actions.pending.count,
        turn_in_flight: chat.turn_in_flight?,
        agent_busy: chat.agent_busy?,
        stop_requested_at: timestamp(chat.stop_requested_at),
        last_message_at: timestamp(chat.last_message_at),
        updated_at: timestamp(chat.updated_at),
        links: {
          app: "/chats/#{chat.id}"
        }
      }
      payload[:recent_messages] = recent_messages_payload(chat) unless compact
      payload
    end

    def recent_messages_payload(chat)
      chat.messages.order(created_at: :desc, id: :desc).limit(RECENT_MESSAGE_LIMIT).map do |message|
        {
          id: message.id,
          role: message.role,
          created_at: timestamp(message.created_at),
          text: message.content.is_a?(Hash) ? message.content["text"].to_s.truncate(500) : nil
        }.compact
      end.reverse
    end

    def recent_workflows_payload(compact:)
      job.workflows.order(created_at: :desc, id: :desc).limit(RECENT_WORKFLOW_LIMIT).map do |candidate|
        workflow_payload(candidate, compact: compact)
      end
    end

    def active_step_for(candidate)
      candidate.steps.active.order(:position).first ||
        candidate.steps.order(position: :desc).first
    end

    def latest_run_for(candidate)
      candidate.steps.includes(:runs).flat_map(&:runs).max_by { |candidate_run| candidate_run.created_at || Time.at(0) }
    end

    def timestamp(value)
      value&.iso8601
    end
  end
end
