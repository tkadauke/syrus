require "set"

class EpicDependency < ApplicationRecord
  belongs_to :epic
  belongs_to :depends_on_epic, class_name: "Epic", optional: true
  belongs_to :depends_on_job, class_name: "Job", optional: true

  validates :depends_on_epic_id, uniqueness: { scope: [ :epic_id, :derived ] }, if: :depends_on_epic_id?
  validate :exactly_one_target
  validate :no_self_reference
  validate :no_cycle

  after_commit :refresh_dependent_epic

  def dependency_succeeded?
    return depends_on_job.dependency_succeeded? if depends_on_job_id.present?

    depends_on_epic.done? || depends_on_epic.fully_approved?
  end

  private

  def exactly_one_target
    target_count = [ depends_on_epic_id.present?, depends_on_job_id.present? ].count(true)

    errors.add(:base, "must reference exactly one dependency target") unless target_count == 1
  end

  def no_self_reference
    return if depends_on_job_id.present?
    return if epic_id.blank? || depends_on_epic_id.blank?

    errors.add(:depends_on_epic, "can't be the same Epic") if epic_id == depends_on_epic_id
  end

  def no_cycle
    return if depends_on_job_id.present?
    return if epic_id.blank? || depends_on_epic_id.blank?
    return if epic_id == depends_on_epic_id

    errors.add(:depends_on_epic, "would create a cycle") if reaches_epic?(depends_on_epic_id, epic_id, Set.new)
  end

  def reaches_epic?(current_id, target_id, seen)
    return true if current_id == target_id
    return false if seen.include?(current_id)

    seen << current_id
    self.class.where(epic_id: current_id).pluck(:depends_on_epic_id).compact.any? do |next_id|
      reaches_epic?(next_id, target_id, seen)
    end
  end

  def refresh_dependent_epic
    return unless epic&.persisted?

    epic.dependencies.reload
    epic.refresh_auto_state!
    epic.block_queued_jobs_if_dependencies_unsatisfied!
  end
end
