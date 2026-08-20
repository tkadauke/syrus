class RunCheckpoint < ApplicationRecord
  STATUSES = %w[pending published failed].freeze
  REF_PREFIX = "refs/syrus/checkpoints/runs".freeze

  belongs_to :run
  belongs_to :workflow
  belongs_to :step
  belongs_to :job
  belongs_to :repository
  belongs_to :user

  validates :step_kind, :commit_sha, :remote_ref, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :run_id, uniqueness: true
  validates :remote_ref, uniqueness: true

  scope :published, -> { where(status: "published") }
  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def self.remote_ref_for(run)
    "#{REF_PREFIX}/#{run.id}"
  end

  def published?
    status == "published"
  end
end
