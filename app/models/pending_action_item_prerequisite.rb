class PendingActionItemPrerequisite < ApplicationRecord
  belongs_to :pending_action_item, inverse_of: :prerequisite_links
  belongs_to :prerequisite, class_name: "PendingActionItem", inverse_of: :dependent_links

  validates :prerequisite_id, uniqueness: { scope: :pending_action_item_id }
  validate :prevent_self_reference
  validate :items_belong_to_same_request
  validate :prevent_cycle

  private

  def prevent_self_reference
    errors.add(:prerequisite, "cannot reference itself") if pending_action_item_id == prerequisite_id
  end

  def items_belong_to_same_request
    return unless pending_action_item && prerequisite
    return if pending_action_item.chat_pending_action_id == prerequisite.chat_pending_action_id

    errors.add(:prerequisite, "must belong to the same pending action")
  end

  def prevent_cycle
    return unless pending_action_item&.persisted? && prerequisite&.persisted?

    pending = [ prerequisite ]
    visited = Set.new
    until pending.empty?
      item = pending.pop
      next unless visited.add?(item.id)

      if item.id == pending_action_item.id
        errors.add(:prerequisite, "would create a cycle")
        return
      end
      pending.concat(item.prerequisites.to_a)
    end
  end
end
