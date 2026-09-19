class MergeTrainMember < ApplicationRecord
  STATES = %w[ included merged failed ].freeze

  belongs_to :merge_train
  belongs_to :job

  validates :state, inclusion: { in: STATES }
  validates :position, presence: true
  validates :job_id, uniqueness: { scope: :merge_train_id }
  validates :position, uniqueness: { scope: :merge_train_id }
end
