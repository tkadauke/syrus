class FilterUsage < ApplicationRecord
  SURFACES = %w[dashboard worker_timeline].freeze
  SUBJECTS = (SmartFolder::SUBJECT_TYPES + %w[worker_timeline]).freeze

  belongs_to :user

  validates :surface, presence: true, inclusion: { in: SURFACES }
  validates :subject, presence: true, inclusion: { in: ->(_) { SmartFolder.subject_types + %w[worker_timeline] } }
  validates :fingerprint, presence: true
  validates :filter_node, presence: true
  validates :label, presence: true
  validates :use_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :fingerprint, uniqueness: { scope: [ :user_id, :surface, :subject ] }
end
