class PendingActionOutcomeDeliveryJob < ApplicationJob
  queue_as :control_plane

  BATCH_SIZE = 100

  def perform
    undelivered_actions.find_each(batch_size: BATCH_SIZE) { |action| deliver(action) }
    undelivered_groups.find_each(batch_size: BATCH_SIZE) { |group| deliver(group) }
  end

  private

  def undelivered_actions
    ChatPendingAction.where(
      pending_action_group_id: nil,
      legacy_outcome: false,
      outcome_wake_enqueued_at: nil,
      state: %w[confirmed rejected cancelled failed]
    )
  end

  def undelivered_groups
    PendingActionGroup.where(
      legacy_outcome: false,
      outcome_wake_enqueued_at: nil,
      state: %w[confirmed rejected]
    )
  end

  def deliver(record)
    record.ensure_outcome_notification!
  rescue StandardError => error
    Rails.logger.error("[PendingActionOutcomeDeliveryJob] #{record.class.name} ##{record.id}: #{error.class}: #{error.message}")
  end
end
