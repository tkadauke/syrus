class JobDeploymentStageStatus < ApplicationRecord
  belongs_to :job

  validates :stage_name, presence: true
  validates :reached_at, presence: true
  validates :stage_name, uniqueness: { scope: :job_id }
end
