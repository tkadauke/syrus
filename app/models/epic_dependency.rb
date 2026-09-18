require "set"

class EpicDependency < ApplicationRecord
  belongs_to :epic
  belongs_to :depends_on_epic, class_name: "Epic", optional: true
  belongs_to :depends_on_job, class_name: "Job", optional: true
  belongs_to :unresolved_chat_proposal, class_name: "ChatProposal", optional: true

  validates :depends_on_epic_id, uniqueness: { scope: [ :epic_id, :derived ] }, if: :depends_on_epic_id?
  validate :exactly_one_target
  validate :no_self_reference
  validate :no_cycle

  after_commit :refresh_dependent_epic

  scope :pending, -> { where(depends_on_epic_id: nil, depends_on_job_id: nil) }

  # A pending row holds an Epic's admission open while a
  # `depends_on_proposal_slugs` token still points at a chat proposal that
  # hasn't confirmed into a real Epic yet -- see
  # ChatEpicProposalDependencyWirer. It carries no real target, so it can
  # never be satisfied until #resolve! swaps in the confirmed Epic.
  def pending?
    depends_on_epic_id.nil? && depends_on_job_id.nil?
  end

  def resolved?
    !pending?
  end

  def dependency_succeeded?
    return false if pending?
    return depends_on_job.dependency_succeeded? if depends_on_job_id.present?

    depends_on_epic.done?
  end

  # Promotes a pending row once the referenced chat proposal confirms into a
  # real Epic. Save runs the cycle/self-reference checks against the now-real
  # dependency, and the after_commit callback re-evaluates the dependent
  # Epic's admission state.
  def resolve!(depends_on_epic:)
    raise "already resolved" if resolved?

    update!(depends_on_epic: depends_on_epic, unresolved_chat_proposal: nil)
  end

  private

  def exactly_one_target
    target_count = [
      depends_on_epic_id.present?,
      depends_on_job_id.present?,
      unresolved_chat_proposal_id.present?
    ].count(true)

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
