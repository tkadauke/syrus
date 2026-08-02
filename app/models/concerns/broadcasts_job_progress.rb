module BroadcastsJobProgress
  extend ActiveSupport::Concern

  included do
    after_create_commit :broadcast_job_progress_created
    after_update_commit :broadcast_job_progress_updated, if: :saved_changes_for_job_progress?
  end

  private

  def broadcast_job_progress_created
    broadcast_job_progress_event("created", changed: saved_changes.keys)
  end

  def broadcast_job_progress_updated
    broadcast_job_progress_event("updated", changed: saved_changes.keys)
  end

  def broadcast_job_progress_event(action, changed:)
    owner_job = job_for_progress_broadcast
    return unless owner_job&.user

    event = {
      type: "job.updated",
      resource: "job",
      id: owner_job.id,
      changed: [ "#{self.class.name.underscore}.#{action}", *changed.map(&:to_s) ].uniq,
      occurred_at: Time.current.iso8601(3)
    }

    AppUserChannel.broadcast_to(owner_job.user, event.as_json)

    chat_session_ids_for(owner_job).each do |session_id|
      AppEvents.broadcast(
        user: owner_job.user,
        type: "chat.updated",
        resource: "chat",
        id: session_id,
        payload: { action: "job_status_changed", job_id: owner_job.id }
      )
    end
  end

  def chat_session_ids_for(job)
    session_ids = ChatProposal.confirmed.where(job: job).distinct.pluck(:chat_session_id)
    session_ids << job.linked_chat_id if job.linked_chat_id.present?
    session_ids.uniq
  end

  def saved_changes_for_job_progress?
    (saved_changes.keys & job_progress_broadcast_columns).any?
  end

  def job_progress_broadcast_columns
    %w[
      state
      started_at
      finished_at
      cleaned_up_at
      failure_count
      artifacts
      details
      agent_outcome
      agent_turns
      agent_pr_title
      agent_summary
      parent_session_id
      head_sha
      cost_usd
      input_tokens
      output_tokens
      cache_creation_input_tokens
      cache_read_input_tokens
      run_diagnostic_id
    ]
  end
end
