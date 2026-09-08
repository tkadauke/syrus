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

  def self.next_index_for(job)
    where(job: job).maximum(:version_index).to_i + 1
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
