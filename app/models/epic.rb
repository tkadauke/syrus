class Epic < ApplicationRecord
  STATES = %w[ backlog ready in_progress done ].freeze

  belongs_to :user
  belongs_to :repository
  has_many :jobs, dependent: :nullify

  enum :state, STATES.index_with(&:itself), validate: true

  validates :title, presence: true
  validate :repository_belongs_to_user

  broadcasts_refreshes_to ->(epic) { [ epic.user, "jobs" ] }
  broadcasts_refreshes_to ->(epic) { [ epic.repository, "jobs" ] }

  after_update_commit :release_blocked_jobs!, if: :saved_change_to_in_progress?

  private

  def repository_belongs_to_user
    return unless repository && user
    return if repository.user_id == user_id

    errors.add(:repository, "must belong to the same user")
  end

  def saved_change_to_in_progress?
    saved_change_to_state? && in_progress?
  end

  def release_blocked_jobs!
    jobs.blocked_by_epic.where(validity: "valid").find_each do |job|
      job.release_epic_block! if job.may_release_epic_block?
    end
  end
end
