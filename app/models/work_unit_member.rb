class WorkUnitMember < ApplicationRecord
  ROLES = %w[primary member dependency repair_target exported_job].freeze

  belongs_to :work_unit
  belongs_to :job

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :job_id, uniqueness: { scope: [ :work_unit_id, :role ] }
end
