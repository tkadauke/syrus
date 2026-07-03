class JobApproval < ApplicationRecord
  belongs_to :job
  belongs_to :user

  validates :user_id, uniqueness: { scope: :job_id }
  validates :approved_at, presence: true

  before_validation :set_approved_at, on: :create

  private

  def set_approved_at
    self.approved_at ||= Time.current
  end
end
