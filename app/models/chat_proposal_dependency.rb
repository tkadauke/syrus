require "set"

class ChatProposalDependency < ApplicationRecord
  belongs_to :proposal, class_name: "ChatProposal"
  belongs_to :depends_on, class_name: "ChatProposal"

  validates :depends_on_id, uniqueness: { scope: :proposal_id }
  validate :no_self_reference
  validate :no_cycle

  private

  def no_self_reference
    return if proposal_id.blank? || depends_on_id.blank?

    errors.add(:depends_on, "can't be the same proposal") if proposal_id == depends_on_id
  end

  def no_cycle
    return if proposal_id.blank? || depends_on_id.blank?
    return if proposal_id == depends_on_id

    errors.add(:depends_on, "would create a cycle") if reaches_proposal?(depends_on_id, proposal_id, Set.new)
  end

  def reaches_proposal?(current_id, target_id, seen)
    return true if current_id == target_id
    return false if seen.include?(current_id)

    seen << current_id
    self.class.where(proposal_id: current_id).pluck(:depends_on_id).any? do |next_id|
      reaches_proposal?(next_id, target_id, seen)
    end
  end
end
