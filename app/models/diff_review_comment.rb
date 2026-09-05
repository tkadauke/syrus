class DiffReviewComment < ApplicationRecord
  STATES = %w[draft submitted resolved superseded].freeze
  SIDES = %w[left right].freeze
  ANCHOR_KINDS = %w[line review].freeze
  REVIEW_ANCHOR_KEY = "review".freeze

  belongs_to :job
  belongs_to :user
  belongs_to :workflow, optional: true
  belongs_to :run, optional: true
  belongs_to :parent, class_name: "DiffReviewComment", optional: true, inverse_of: :replies
  has_many :replies, class_name: "DiffReviewComment", foreign_key: :parent_id, inverse_of: :parent, dependent: :nullify

  attribute :context, :json, default: -> { {} }

  validates :surface, presence: true
  validates :anchor_kind, presence: true, inclusion: { in: ANCHOR_KINDS }
  validates :path, presence: true, if: :line_anchor?
  validates :side, presence: true, inclusion: { in: SIDES }, if: :line_anchor?
  validates :state, presence: true, inclusion: { in: STATES }
  validates :body, presence: true
  validates :old_line, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :new_line, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :side_line_anchor_present, if: :line_anchor?
  validate :workflow_belongs_to_job
  validate :run_belongs_to_job
  validate :run_belongs_to_workflow
  validate :parent_belongs_to_same_job

  before_validation :normalize_strings
  before_validation :default_context
  before_save :stamp_lifecycle_transition, if: :will_save_change_to_state?

  def line_anchor?
    anchor_kind != "review"
  end

  scope :ordered, -> { order(:path, :side, :old_line, :new_line, :created_at, :id) }
  scope :for_surface, ->(surface) { where(surface: surface) if surface.present? }
  scope :for_path, ->(path) { where(path: path) if path.present? }
  scope :for_state, ->(state) { where(state: state) if state.present? }
  scope :for_base_ref, ->(base_ref) { where(base_ref: base_ref) if base_ref.present? }
  scope :for_head_ref, ->(head_ref) { where(head_ref: head_ref) if head_ref.present? }
  scope :for_workflow, ->(workflow_id) { where(workflow_id: workflow_id) if workflow_id.present? }
  scope :for_run, ->(run_id) { where(run_id: run_id) if run_id.present? }

  def anchor_key
    return REVIEW_ANCHOR_KEY unless line_anchor?

    [
      side,
      old_line || "",
      new_line || ""
    ].join(":")
  end

  def self.build_reply(parent:, user:, body:)
    parent.job.diff_review_comments.build(
      user: user,
      parent: parent,
      surface: parent.surface,
      base_ref: parent.base_ref,
      head_ref: parent.head_ref,
      anchor_kind: parent.anchor_kind,
      path: parent.path,
      side: parent.side,
      old_line: parent.old_line,
      new_line: parent.new_line,
      diff_hunk: parent.diff_hunk,
      workflow_id: parent.workflow_id,
      run_id: parent.run_id,
      body: body,
      state: "draft"
    )
  end

  def submit!
    update!(state: "submitted", submitted_at: Time.current)
  end

  def resolve!
    update!(state: "resolved", resolved_at: Time.current)
  end

  def supersede!
    update!(state: "superseded", superseded_at: Time.current)
  end

  private

  def normalize_strings
    self.surface = surface.to_s.strip.presence || "job_diff"
    self.base_ref = base_ref.to_s.strip.presence
    self.head_ref = head_ref.to_s.strip.presence
    self.anchor_kind = anchor_kind.to_s.strip.presence || "line"
    self.body = body.to_s.strip

    if line_anchor?
      self.path = path.to_s.strip
      self.side = side.to_s.strip
      self.diff_hunk = diff_hunk.to_s.presence
    else
      self.path = nil
      self.side = nil
      self.old_line = nil
      self.new_line = nil
      self.diff_hunk = nil
    end
  end

  def default_context
    self.context = {} unless context.is_a?(Hash)
  end

  def side_line_anchor_present
    return if side == "left" && old_line.present?
    return if side == "right" && new_line.present?
    return unless SIDES.include?(side)

    errors.add(:base, "left-side comments require old_line; right-side comments require new_line")
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
    return unless run && workflow && run.step&.workflow_id != workflow.id

    errors.add(:run, "must belong to the same workflow")
  end

  def parent_belongs_to_same_job
    return unless parent && job_id && parent.job_id != job_id

    errors.add(:parent, "must belong to the same job")
  end

  def stamp_lifecycle_transition
    now = Time.current
    self.submitted_at ||= now if state == "submitted"
    self.resolved_at ||= now if state == "resolved"
    self.superseded_at ||= now if state == "superseded"
  end
end
