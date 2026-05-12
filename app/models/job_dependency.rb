require "set"

class JobDependency < ApplicationRecord
  belongs_to :job
  belongs_to :depends_on_job, class_name: "Job"
  belongs_to :created_by_user, class_name: "User", optional: true

  enum :source, { parsed: "parsed", manual: "manual" }, validate: true

  validate :no_self_reference
  validate :no_cycle

  private

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
    self.class.where(job_id: current_id).pluck(:depends_on_job_id).any? do |next_id|
      reaches_job?(next_id, target_id, seen)
    end
  end
end
