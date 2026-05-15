require "set"

class JobDependency < ApplicationRecord
  belongs_to :job
  belongs_to :depends_on_job, class_name: "Job", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true

  enum :source, { parsed: "parsed", manual: "manual" }, validate: true

  validate :exactly_one_target
  validate :no_self_reference
  validate :no_cycle
  validate :pending_fields_consistent

  after_save_commit :materialize_derived_epic_dependency, if: :resolved?

  scope :resolved, -> { where.not(depends_on_job_id: nil) }
  scope :pending, -> { where(depends_on_job_id: nil) }

  def pending?
    depends_on_job_id.nil?
  end

  def resolved?
    !pending?
  end

  def unresolved_slug
    return nil unless pending?
    "#{unresolved_owner}/#{unresolved_repo}##{unresolved_number}"
  end

  # Promote a pending row to a resolved row. Caller passes the Job that
  # now exists for the previously-unresolved reference; we clear the
  # unresolved_* columns and set depends_on_job_id. Save runs the cycle
  # check against the now-real dependency.
  def resolve!(depends_on_job:)
    raise "already resolved" if resolved?

    update!(
      depends_on_job: depends_on_job,
      unresolved_owner: nil,
      unresolved_repo: nil,
      unresolved_number: nil
    )
  end

  private

  def exactly_one_target
    if depends_on_job_id.blank? && unresolved_number.blank?
      errors.add(:base, "must reference a Job or carry an unresolved reference")
    elsif depends_on_job_id.present? && unresolved_number.present?
      errors.add(:base, "can't be both resolved and pending")
    end
  end

  def pending_fields_consistent
    return if depends_on_job_id.present?

    if unresolved_owner.blank? || unresolved_repo.blank? || unresolved_number.blank?
      errors.add(:base, "pending rows need owner, repo, and number")
    end
  end

  def no_self_reference
    return if job_id.blank? || depends_on_job_id.blank?

    errors.add(:depends_on_job, "can't be the same Job") if job_id == depends_on_job_id
  end

  def no_cycle
    return if job_id.blank? || depends_on_job_id.blank?
    return if job_id == depends_on_job_id

    errors.add(:depends_on_job, "would create a cycle") if reaches_job?(depends_on_job_id, job_id, Set.new)
  end

  def reaches_job?(current_id, target_id, seen)
    return true if current_id == target_id
    return false if seen.include?(current_id)

    seen << current_id
    self.class.resolved.where(job_id: current_id).pluck(:depends_on_job_id).any? do |next_id|
      reaches_job?(next_id, target_id, seen)
    end
  end

  def materialize_derived_epic_dependency
    dependent_epic = job&.epic
    upstream_epic = depends_on_job&.epic
    return if dependent_epic.blank? || upstream_epic.blank?
    return if dependent_epic == upstream_epic

    EpicDependency.find_or_create_by!(
      epic: dependent_epic,
      depends_on_epic: upstream_epic,
      derived: true
    )
  end
end
