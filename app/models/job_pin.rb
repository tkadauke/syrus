class JobPin < ApplicationRecord
  belongs_to :user
  belongs_to :job

  validates :job_id, uniqueness: { scope: :user_id }
  validate :job_belongs_to_user

  private

  def job_belongs_to_user
    return if user_id.blank? || job.blank?
    return if job.user_id == user_id

    errors.add(:job, "must belong to the user")
  end
end
