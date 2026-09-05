class FilterUsage < ApplicationRecord
  SURFACES = %w[dashboard memories worker_timeline agent_activity agent_activity_admin].freeze
  EXTRA_SUBJECTS = %w[worker_timeline agent_activity].freeze

  def self.subjects
    (SmartFolder.subject_types + EXTRA_SUBJECTS).uniq
  end

  belongs_to :user

  validates :surface, presence: true, inclusion: { in: SURFACES }
  validates :subject, presence: true, inclusion: { in: ->(_) { FilterUsage.subjects } }
  validates :fingerprint, presence: true
  validates :filter_node, presence: true
  validates :label, presence: true
  validates :use_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :fingerprint, uniqueness: { scope: [ :user_id, :surface, :subject ] }
end
