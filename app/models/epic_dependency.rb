require "set"

class EpicDependency < ApplicationRecord
  belongs_to :epic
  belongs_to :depends_on_epic, class_name: "Epic"

  validates :depends_on_epic_id, uniqueness: { scope: [ :epic_id, :derived ] }
  validate :no_self_reference
  validate :no_cycle

  after_commit :refresh_dependent_epic
  after_commit :broadcast_epic_graph_refreshes

  private

  def no_self_reference
    return if epic_id.blank? || depends_on_epic_id.blank?

    errors.add(:depends_on_epic, "can't be the same Epic") if epic_id == depends_on_epic_id
  end

  def no_cycle
    return if epic_id.blank? || depends_on_epic_id.blank?
    return if epic_id == depends_on_epic_id

    errors.add(:depends_on_epic, "would create a cycle") if reaches_epic?(depends_on_epic_id, epic_id, Set.new)
  end

  def reaches_epic?(current_id, target_id, seen)
    return true if current_id == target_id
    return false if seen.include?(current_id)

    seen << current_id
    self.class.where(epic_id: current_id).pluck(:depends_on_epic_id).any? do |next_id|
      reaches_epic?(next_id, target_id, seen)
    end
  end

  def refresh_dependent_epic
    epic.refresh_auto_state! if epic&.persisted?
  end

  def broadcast_epic_graph_refreshes
    [ epic, depends_on_epic ].compact.uniq.each do |epic_record|
      broadcast_refresh_later_to(epic_record)
    end
  end
end
