class DiffReviewVersion < ApplicationRecord
  belongs_to :job
  belongs_to :workflow, optional: true
  belongs_to :run, optional: true
  has_many :diff_review_comments, dependent: :restrict_with_exception

  attribute :files_snapshot, :json, default: -> { [] }
  attribute :metadata, :json, default: -> { {} }

  validates :version_index, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :base_sha, :head_sha, :source_key, presence: true
  validates :truncated, inclusion: { in: [ true, false ] }
  validates :version_index, uniqueness: { scope: :job_id }
  validates :source_key, uniqueness: { scope: %i[job_id base_sha head_sha] }
  validate :files_snapshot_array
  validate :metadata_hash
  validate :workflow_belongs_to_job
  validate :run_belongs_to_job
  validate :run_belongs_to_workflow

  before_validation :normalize_strings
  before_validation :default_json_columns

  scope :ordered, -> { order(:version_index, :id) }
  scope :latest_first, -> { order(version_index: :desc, id: :desc) }
  scope :all_changes, -> { where(reason: "source_diff") }

  def self.next_index_for(job)
    where(job: job).maximum(:version_index).to_i + 1
  end

  def self.default_for_review(job)
    reusable_all_changes_for(job).latest_first.first || reviewable_for(job).latest_first.first
  end

  def self.reusable_all_changes_for(job)
    reviewable_for(job).all_changes
  end

  def self.reviewable_for(job)
    scope = where(job: job)
    default_branch = job.repository&.default_branch.to_s.strip.presence
    default_branch ? scope.where.not(reason: "source_diff", head_sha: default_branch) : scope
  end

  # Best-effort provenance lookup for a Run/Workflow that wants to tag an
  # artifact with the DiffReviewVersion it was captured against. Prefers an
  # exact run_id match (the Run that produced the diff being reviewed);
  # falls back to the most recent version recorded for the same workflow
  # (e.g. a later review-step Run looking at an earlier implement Run's
  # diff). Deliberately does not attempt ancestry/range containment beyond
  # that — see the "Make job review artifacts version-aware" design note.
  def self.best_match_for(job_id:, run_id: nil, workflow_id: nil)
    return nil if job_id.blank?

    scope = where(job_id: job_id)
    by_run = run_id.present? ? scope.where(run_id: run_id).latest_first.first : nil
    by_run || (workflow_id.present? ? scope.where(workflow_id: workflow_id).latest_first.first : nil)
  end

  private

  def normalize_strings
    self.base_sha = base_sha.to_s.strip
    self.head_sha = head_sha.to_s.strip
    self.base_ref = base_ref.to_s.strip.presence
    self.head_ref = head_ref.to_s.strip.presence
    self.source_key = source_key.to_s.strip
    self.trigger_kind = trigger_kind.to_s.strip.presence
    self.label = label.to_s.strip.presence
    self.reason = reason.to_s.strip.presence
  end

  def default_json_columns
    self.files_snapshot = [] unless files_snapshot.is_a?(Array)
    self.metadata = {} unless metadata.is_a?(Hash)
  end

  def files_snapshot_array
    errors.add(:files_snapshot, "must be an array") unless files_snapshot.is_a?(Array)
  end

  def metadata_hash
    errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
  end

  def workflow_belongs_to_job
    return unless workflow && job_id && workflow.job_id != job_id

    errors.add(:workflow, "must belong to the same job")
  end

  def run_belongs_to_job
    return unless run && job_id && run.job_id != job_id

    errors.add(:run, "must belong to the same job")
  end

  def run_belongs_to_workflow
    return unless run && workflow && run.workflow_id != workflow.id

    errors.add(:run, "must belong to the same workflow")
  end
end
