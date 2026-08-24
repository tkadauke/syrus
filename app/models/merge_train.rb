class MergeTrain < ApplicationRecord
  # An attempt to land an Epic's children together: build one
  # integration branch, grade it once, and land it atomically. See
  # docs/plans/landing-merge-train.md.
  STATES = %w[ building grading landing succeeded failed cancelled ].freeze
  TERMINAL_STATES = %w[ succeeded failed cancelled ].freeze

  belongs_to :epic, optional: true
  belongs_to :repository
  has_many :members, -> { order(:position) }, class_name: "MergeTrainMember", dependent: :destroy, inverse_of: :merge_train

  has_many :jobs, through: :members

  validates :base_branch, presence: true
  validates :state, inclusion: { in: STATES }
  validates :priority, inclusion: { in: Job::PRIORITIES }, allow_nil: true
  validate :epic_or_priority_but_not_both

  scope :active, -> { where.not(state: TERMINAL_STATES) }

  def member_jobs
    members.includes(:job).map(&:job)
  end

  def epic_backed? = epic_id.present?

  def bundle_backed? = epic_id.blank? && priority.present?

  def default_integration_branch
    if epic_backed?
      "syrus/merge-train-epic-#{epic_id}-#{id}"
    else
      "syrus/job-bundle-#{id}"
    end
  end

  def terminal?
    TERMINAL_STATES.include?(state)
  end

  private

  def epic_or_priority_but_not_both
    epic_backed = epic_id.present?
    bundle_backed = priority.present?

    if epic_backed && bundle_backed
      errors.add(:base, "must not be both epic-backed and bundle-backed")
    elsif !epic_backed && !bundle_backed
      errors.add(:base, "must be either epic-backed (epic present) or bundle-backed (priority present)")
    end
  end
end
