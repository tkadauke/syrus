class CognitiveEngagementEvent < ApplicationRecord
  SOURCE_TYPES = %w[
    authored_line
    diff_review_comment
    pr_review_comment
    job_approval
    chat_file_reference
    viewed_range
  ].freeze
  ENGAGEMENT_KINDS = %w[authored reviewed approved discussed viewed].freeze
  ANCHOR_KINDS = %w[range file repository].freeze
  SIDES = %w[left right].freeze
  QUALITIES = %w[
    high
    normal
    shallow
    rubber_stamp
    inferred
  ].freeze
  DEFAULT_WEIGHTS = {
    "authored" => BigDecimal("1.0"),
    "reviewed" => BigDecimal("0.8"),
    "approved" => BigDecimal("0.5"),
    "discussed" => BigDecimal("0.3"),
    "viewed" => BigDecimal("0.2")
  }.freeze

  belongs_to :repository
  belongs_to :user
  belongs_to :diff_review_version, optional: true

  attribute :metadata, :json, default: -> { {} }

  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validates :engagement_kind, presence: true, inclusion: { in: ENGAGEMENT_KINDS }
  validates :evidence_type, :evidence_key, :anchor_key, :occurred_at, presence: true
  validates :anchor_kind, presence: true, inclusion: { in: ANCHOR_KINDS }
  validates :side, inclusion: { in: SIDES }, allow_nil: true
  validates :quality, inclusion: { in: QUALITIES }, allow_nil: true
  validates :start_line, :end_line, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :weight, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :evidence_key, uniqueness: {
    scope: %i[repository_id user_id source_type anchor_key],
    message: "has already been recorded for this source and anchor"
  }
  validate :range_anchor_shape
  validate :diff_review_version_belongs_to_repository

  before_validation :normalize_fields
  before_validation :default_weight
  before_validation :default_metadata

  def self.default_weight_for(engagement_kind)
    DEFAULT_WEIGHTS.fetch(engagement_kind.to_s)
  end

  private

  def normalize_fields
    self.source_type = source_type.to_s.strip.presence
    self.engagement_kind = engagement_kind.to_s.strip.presence
    self.evidence_type = evidence_type.to_s.strip.presence
    self.evidence_key = evidence_key.to_s.strip.presence
    self.commit_sha = commit_sha.to_s.strip.presence
    self.base_sha = base_sha.to_s.strip.presence
    self.head_sha = head_sha.to_s.strip.presence
    self.anchor_kind = anchor_kind.to_s.strip.presence || "range"
    self.path = path.to_s.strip.presence
    self.side = side.to_s.strip.presence
    self.quality = quality.to_s.strip.presence
    normalize_lines
    self.anchor_key = normalized_anchor_key
  end

  def normalize_lines
    self.start_line = normalized_positive_integer(start_line)
    self.end_line = normalized_positive_integer(end_line)
    self.end_line ||= start_line if start_line.present?
    return unless start_line.present? && end_line.present? && start_line > end_line

    self.start_line, self.end_line = end_line, start_line
  end

  def normalized_positive_integer(value)
    return nil if value.blank?

    Integer(value, exception: false)
  end

  def default_weight
    self.weight ||= self.class.default_weight_for(engagement_kind) if ENGAGEMENT_KINDS.include?(engagement_kind)
  end

  def default_metadata
    self.metadata = {} unless metadata.is_a?(Hash)
  end

  def range_anchor_shape
    if anchor_kind == "range"
      errors.add(:path, "must be present for range anchors") if path.blank?
      errors.add(:start_line, "must be present for range anchors") if start_line.blank?
      errors.add(:end_line, "must be present for range anchors") if end_line.blank?
    elsif anchor_kind == "file"
      errors.add(:path, "must be present for file anchors") if path.blank?
      errors.add(:start_line, "must be blank for file anchors") if start_line.present?
      errors.add(:end_line, "must be blank for file anchors") if end_line.present?
    else
      errors.add(:path, "must be blank for repository anchors") if path.present?
      errors.add(:start_line, "must be blank for repository anchors") if start_line.present?
      errors.add(:end_line, "must be blank for repository anchors") if end_line.present?
    end
  end

  def normalized_anchor_key
    if anchor_kind == "range"
      [ "range", path, side, start_line, end_line ].join(":")
    elsif anchor_kind == "file"
      [ "file", path ].join(":")
    else
      "repository"
    end
  end

  def diff_review_version_belongs_to_repository
    return unless diff_review_version && repository_id && diff_review_version.job&.repository_id != repository_id

    errors.add(:diff_review_version, "must belong to the same repository")
  end
end
