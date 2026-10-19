module PendingActionGroups
  module Confirmations
    class DependencySequenced < Confirmation
      def confirm_all!(user: nil)
        return false unless group.start_group_confirmation!(user: user)

        group.chat_pending_actions.pending.order(:id).each do |member|
          member.suppress_outcome_notification = true
          member.start_confirmation!(user: user, status: "queued", step: "Waiting for selected dependencies...")
        end
        BulkRefreshRetrySequenceJob.perform_later(group.id)
        ConfirmResult.new(group: group, member_results: [])
      end
    end
  end
end
