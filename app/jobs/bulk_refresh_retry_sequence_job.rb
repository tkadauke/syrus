class BulkRefreshRetrySequenceJob < ApplicationJob
  queue_as :control_plane

  POLL_INTERVAL = 15.seconds

  def perform(pending_action_group_id)
    group = PendingActionGroup.find(pending_action_group_id)
    return unless group.confirming?

    members = group.chat_pending_actions.order(:id).to_a
    by_job_id = members.index_by { |member| member.payload.to_h["job_id"].to_i }
    settle_launched_members(members)
    launch_ready_members(members, by_job_id)

    if members.any? { |member| member.reload.confirming? }
      self.class.set(wait: POLL_INTERVAL).perform_later(group.id)
    else
      group.finish_group_confirmation!
    end
  end

  private

  def settle_launched_members(members)
    members.select { |member| member.confirming? && member.result.is_a?(Workflow) }.each do |member|
      workflow = member.result.reload
      next unless workflow.terminal?

      member.suppress_outcome_notification = true
      if workflow.succeeded?
        member.complete_sequenced_confirmation!
      else
        member.fail_confirmation!(ArgumentError.new("Refresh workflow #{workflow.slug} ended #{workflow.state}."))
      end
    end
  end

  def launch_ready_members(members, by_job_id)
    members.select { |member| member.confirming? && member.result.nil? }.each do |member|
      upstream = Array(member.payload.to_h["selected_upstream_job_ids"]).filter_map { |id| by_job_id[id.to_i] }
      failed = upstream.find(&:failed?)
      if failed
        member.suppress_outcome_notification = true
        member.fail_confirmation!(ArgumentError.new("Selected upstream refresh failed for job_id #{failed.payload['job_id']}."))
        next
      end
      next unless upstream.all?(&:confirmed?)

      member.suppress_outcome_notification = true
      member.execute_confirmation!(finalize: false)
    end
  end
end
