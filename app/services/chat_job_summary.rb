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
      .includes(:epic, :auto_retry_attempts, workflows: :steps)
      .index_by(&:id)
    epic_counts = epic_progress(jobs.values.filter_map(&:epic_id).uniq)
    transition_times = outcome_transition_times(jobs.keys)

    associations.to_h do |chat_id, job_ids|
      rows = job_ids.filter_map { |id| jobs[id] }.map do |job|
        row_for(job, read_at[chat_id], transition_times[job.id], epic_counts[job.epic_id])
      end
      active_count = rows.count { |row| row[:group] == "running" }
      outcome = rows.any? { |row| row[:group] == "failed" } ? "failed" : rows.any? { |row| row[:group] == "ready" } ? "ready" : nil
      [ chat_id, { active_count: active_count, outcome: outcome, jobs: rows } ]
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
      [ id, {
        total: total,
        state_counts: counts.to_h,
        needs_attention: counts["failed"].positive? || attention_counts[id].to_i.positive?
      } ]
    end
  end

  def visual_state_for(state, closure_reason)
    return VISUAL_STATE_BY_CLOSURE_REASON[closure_reason] if state == "closed"

    VISUAL_STATE_BY_JOB_STATE.fetch(state, state)
  end

  def outcome_transition_times(job_ids)
    StateTransition.where(subject_type: "Job", subject_id: job_ids, to_state: %w[implemented failed])
      .group(:subject_id).maximum(:created_at)
  end

  def row_for(job, read_at, transition_time, progress)
    workflow = job.workflows.select { |item| Workflow::TriggerKind::ACTIVE_STATES.include?(item.state) }
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
      slug: job.slug,
      state: job.state,
      step: workflow&.steps&.find { |step| Workflow::TriggerKind::ACTIVE_STATES.include?(step.state) }&.kind || workflow&.trigger_kind,
      group: group,
      started_at: workflow&.started_at&.iso8601,
      finished_at: group.in?(%w[failed ready]) ? (transition_time || job.updated_at)&.iso8601 : nil,
      app_path: "/jobs/#{job.id}",
      epic: job.epic && progress ? {
        id: job.epic.id,
        slug: job.epic.slug,
        title: job.epic.title,
        total: progress[:total],
        state_counts: progress[:state_counts],
        needs_attention: progress[:needs_attention]
      } : nil
    }.compact
  end

  def pending_retry?(job)
    job.auto_retry_attempts.any? { |attempt| attempt.performed_at.nil? && attempt.skipped_reason.nil? }
  end

  def newer_than_read?(finished_at, read_at)
    read_at.nil? || finished_at > read_at
  end
end
