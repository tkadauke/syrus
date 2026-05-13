class ChatPendingAction < ApplicationRecord
  ACTIONS = %w[
    add_repo_note
    remove_repo_note
    cancel_job
    retry_job
    rebase_job
  ].freeze
  STATES = %w[ pending confirmed rejected ].freeze
  REQUESTED_BY = %w[ agent operator ].freeze

  attribute :payload, :json, default: -> { {} }

  belongs_to :chat_session

  enum :state, STATES.index_with(&:itself), validate: true

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :requested_by, presence: true, inclusion: { in: REQUESTED_BY }
  validate :payload_matches_action

  def confirm!
    with_lock do
      return false unless pending?

      ApplicationRecord.transaction do
        apply!
        update!(state: "confirmed", confirmed_at: Time.current)
      end
    end
  end

  def reject!
    with_lock do
      return false unless pending?

      update!(state: "rejected", rejected_at: Time.current)
    end
  end

  private

  def apply!
    case action
    when "add_repo_note"
      chat_session.repository.repository_notes.create!(
        body: payload.fetch("body").to_s,
        author: "agent"
      )
    when "remove_repo_note"
      note = chat_session.repository.repository_notes.active.find(payload.fetch("id"))
      note.remove!
    when "cancel_job"
      action_job.cancel_active_runs_and_close!("cancelled")
    when "retry_job"
      job = action_job
      raise ArgumentError, "Thread is closed — use Start over to begin a new one." if job.closed?
      raise ArgumentError, "A Run is already in progress — wait for it to finish." if job.any_active_run?
      unless job.latest_workflow&.retry_as_new_workflow_available?
        raise ArgumentError, "Retry is not available for this Job."
      end

      job.sync_skip_prepare_from_source!
      workflow = Workflows::Retry.instantiate(job: job)
      StepDispatcher.start_workflow(workflow)
    when "rebase_job"
      job = action_job
      unless job.pr_number.present? || job.external_pr_number.present?
        raise ArgumentError, "No PR on this Job to rebase."
      end
      if job.workflows.active.where(trigger_kind: "rebase").exists?
        raise ArgumentError, "A rebase is already in progress — wait for it to finish."
      end

      workflow = Workflows::Rebase.instantiate(job: job)
      StepDispatcher.start_workflow(workflow)
    else
      raise ArgumentError, "unknown pending action: #{action}"
    end
  end

  def payload_matches_action
    case action
    when "add_repo_note"
      errors.add(:payload, "body is required") if payload["body"].to_s.strip.blank?
    when "remove_repo_note"
      errors.add(:payload, "id is required") unless payload["id"].present?
    when "cancel_job", "retry_job", "rebase_job"
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end
  end

  def action_job
    chat_session.repository.jobs.find(payload.fetch("job_id"))
  end
end
