class JobTag < ApplicationRecord
  belongs_to :job
  belongs_to :tag

  validates :tag_id, uniqueness: { scope: :job_id }
  validate :tag_and_job_share_user

  private

  def tag_and_job_share_user
    return if tag.nil? || job.nil?
    return if tag.user_id == job.user_id
    return if tag.user&.admin?
    return if job.repository.member_at_least?(tag.user, "write")

    errors.add(:tag, "must belong to the job owner")
  end
end
