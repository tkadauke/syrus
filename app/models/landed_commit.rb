class LandedCommit < ApplicationRecord
  KINDS = %w[ implementation integration_merge reconcile ].freeze

  belongs_to :landable, polymorphic: true

  validates :sha, presence: true, uniqueness: true
  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :position, presence: true
end
