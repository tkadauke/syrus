class ChatJobSummary
  READY_STATES = %w[implemented approved landing].freeze
  VISUAL_STATE_BY_JOB_STATE = {
    "landing" => "approved",
    "no_change_needed" => "implemented"
  }.freeze
  VISUAL_STATE_BY_CLOSURE_REASON = Epic::MERGED_JOB_CLOSURE_REASONS.index_with { "merged" }
    .merge("no_changes" => "implemented").freeze
  # A chat owns Job visibility through either confirmed proposal lineage or the
  # Job attachment selected by Job#discussion_chat. Ordinary Job attachments
  # after the earliest one are context only and deliberately do not associate
  # the Job with another sidebar row.
  def self.for(chat_sessions:, user:)
    new(chat_sessions: chat_sessions, user: user).call
  end

  def initialize(chat_sessions:, user:)
    @chat_sessions = Array(chat_sessions)
    @user = user
  end

  def call
    return {} if chat_ids.empty?

    read_at = participant_read_times
    jobs = Job.where(id: associations.values.flatten.uniq)
      .includes(:epic, :auto_retry_attempts)
      .index_by(&:id)
    workflows_by_job = summary_workflows_by_job(jobs.keys)
    steps_by_workflow = summary_steps_by_workflow(workflows_by_job.values.flatten.map(&:id))
    transition_times = outcome_transition_times(jobs.keys)
    epic_progress = epic_progress(jobs.values.filter_map(&:epic_id).uniq)

    associations.to_h do |chat_id, job_ids|
      rows = job_ids.filter_map { |id| jobs[id] }.map do |job|
        row_for(job, read_at[chat_id], transition_times[job.id],
          workflows_by_job[job.id] || [], steps_by_workflow)
      end
      active_count = rows.count { |row| row[:group] == "running" }
      outcome = rows.any? { |row| row[:group] == "failed" } ? "failed" : rows.any? { |row| row[:group] == "ready" } ? "ready" : nil
      visible_rows = rows.select { |row| row[:group] }
      epics = visible_rows.filter_map { |row| jobs[row[:id]]&.epic }.uniq(&:id).to_h do |epic|
        [ epic.id, epic_json(epic, epic_progress.fetch(epic.id)) ]
      end
      [ chat_id, { active_count: active_count, outcome: outcome, jobs: visible_rows, epics: epics } ]
    end
  end

  private

  attr_reader :chat_sessions, :user

  def chat_ids = @chat_ids ||= chat_sessions.map(&:id)

  def participant_read_times
    participant = ChatParticipant.where(chat_session_id: chat_ids, user_id: user.id).pluck(:chat_session_id, :last_read_at).to_h
    chat_sessions.to_h { |chat| [ chat.id, participant[chat.id] || chat.last_read_at ] }
  end

  def associations
    @associations ||= begin
      pairs = ChatProposal.confirmed.where(chat_session_id: chat_ids).where.not(job_id: nil).pluck(:chat_session_id, :job_id)
      candidate_attachments = ChatAttachment.where(chat_session_id: chat_ids, attachable_type: "Job")
        .order(:attachable_id, :attached_at, :id).pluck(:chat_session_id, :attachable_id)
      first_chat_by_job = ChatAttachment.where(attachable_type: "Job", attachable_id: candidate_attachments.map(&:last).uniq)
        .joins(:chat_session).merge(ChatSession.active).group_by(&:attachable_id)
        .transform_values { |items| items.min_by { |item| [ item.attached_at, item.id ] }.chat_session_id }
      pairs.concat(candidate_attachments.select { |chat_id, job_id| first_chat_by_job[job_id] == chat_id })
      pairs.group_by(&:first).transform_values { |items| items.map(&:last).uniq }
    end
  end

  # The sidebar reads four workflow columns and two step columns to show a
  # status pill. Loading the full rows meant hauling `workflows.artifacts`
  # -- averaging 152KB and peaking above 11MB -- for every workflow of every
  # linked Job, then discarding it. Measured at 2.7s for the workflows query
  # and 2.0s for the steps query on a single sidebar load.
  WORKFLOW_SUMMARY_COLUMNS = %i[ id job_id state trigger_kind created_at started_at ].freeze
  STEP_SUMMARY_COLUMNS = %i[ id workflow_id state kind ].freeze

  def summary_workflows_by_job(job_ids)
    return {} if job_ids.empty?

    Workflow.where(job_id: job_ids).select(*WORKFLOW_SUMMARY_COLUMNS).group_by(&:job_id)
  end

  def summary_steps_by_workflow(workflow_ids)
    return {} if workflow_ids.empty?

    Step.where(workflow_id: workflow_ids).select(*STEP_SUMMARY_COLUMNS).group_by(&:workflow_id)
  end

  def outcome_transition_times(job_ids)
    StateTransition.where(subject_type: "Job", subject_id: job_ids, to_state: %w[implemented failed])
      .group(:subject_id).maximum(:created_at)
  end

  def epic_progress(epic_ids)
    return {} if epic_ids.empty?

    grouped_counts = Job.where(epic_id: epic_ids).group(:epic_id, :state, :closure_reason).count
    attention_counts = Job.where(epic_id: epic_ids, needs_attention: true).group(:epic_id).count
    epic_ids.to_h do |id|
      counts = Hash.new(0)
      total = 0
      grouped_counts.each do |(epic_id, state, closure_reason), count|
        next unless epic_id == id

        total += count
        visual_state = visual_state_for(state, closure_reason)
        counts[visual_state] += count if visual_state
      end
      [ id, { total: total, state_counts: counts.to_h, needs_attention: counts["failed"].positive? || attention_counts[id].to_i.positive? } ]
    end
  end

  def epic_json(epic, progress)
    {
      id: epic.id,
      slug: epic.slug,
      title: epic.title,
      total: progress[:total],
      state_counts: progress[:state_counts],
      needs_attention: progress[:needs_attention]
    }
  end

  def visual_state_for(state, closure_reason)
    return VISUAL_STATE_BY_CLOSURE_REASON[closure_reason] if state == "closed"

    VISUAL_STATE_BY_JOB_STATE.fetch(state, state)
  end

  def active_step_kind(workflow, steps_by_workflow)
    return nil unless workflow

    (steps_by_workflow[workflow.id] || [])
      .find { |step| Workflow::TriggerKind::ACTIVE_STATES.include?(step.state) }&.kind
  end

  def row_for(job, read_at, transition_time, job_workflows, steps_by_workflow)
    workflow = job_workflows.select { |item| Workflow::TriggerKind::ACTIVE_STATES.include?(item.state) }
      .reject { |item| item.landing_workflow? || item.trigger_kind == "ci_failure" }
      .max_by { |item| [ item.created_at, item.id ] }
    group = if workflow || pending_retry?(job)
      "running"
    elsif job.failed? && newer_than_read?(transition_time || job.updated_at, read_at)
      "failed"
    elsif READY_STATES.include?(job.state) && newer_than_read?(transition_time || job.updated_at, read_at)
      "ready"
    end

    {
      id: job.id,
      epic_id: job.epic_id,
      slug: job.slug,
      state: job.state,
      step: active_step_kind(workflow, steps_by_workflow) || workflow&.trigger_kind,
      group: group,
      started_at: workflow&.started_at&.iso8601,
      finished_at: group.in?(%w[failed ready]) ? (transition_time || job.updated_at)&.iso8601 : nil,
      app_path: "/jobs/#{job.id}"
    }.compact
  end

  def pending_retry?(job)
    job.auto_retry_attempts.any? { |attempt| attempt.performed_at.nil? && attempt.skipped_reason.nil? }
  end

  def newer_than_read?(finished_at, read_at)
    read_at.nil? || finished_at > read_at
  end
end
