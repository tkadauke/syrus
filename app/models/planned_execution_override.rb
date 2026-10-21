class PlannedExecutionOverride < ApplicationRecord
  belongs_to :job
  belongs_to :workflow, optional: true
  belongs_to :user

  validates :profile, :reason, :provenance, presence: true
  validates :previous_placement, :replacement_placement, presence: true
end
