class DiffReviewComment < ApplicationRecord
  STATES = %w[draft submitted resolved superseded].freeze
  SIDES = %w[left right].freeze

  belongs_to :job
  belongs_to :user
  belongs_to :workflow, optional: true
  belongs_to :run, optional: true

  attribute :context, :json, default: -> { {} }

  validates :surface, presence: true
  validates :path, presence: true
  validates :side, presence: true, inclusion: { in: SIDES }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :body, presence: true
  validates :old_line, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :new_line, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :side_line_anchor_present
  validate :workflow_belongs_to_job
  validate :run_belongs_to_job
  validate :run_belongs_to_workflow

  before_validation :normalize_strings
  before_validation :default_context
  before_save :stamp_lifecycle_transition, if: :will_save_change_to_state?

  scope :ordered, -> { order(:path, :side, :old_line, :new_line, :created_at, :id) }
  scope :for_surface, ->(surface) { where(surface: surface) if surface.present? }
  scope :for_path, ->(path) { where(path: path) if path.present? }
  scope :for_state, ->(state) { where(state: state) if state.present? }
  scope :for_base_ref, ->(base_ref) { where(base_ref: base_ref) if base_ref.present? }
  scope :for_head_ref, ->(head_ref) { where(head_ref: head_ref) if head_ref.present? }
  scope :for_workflow, ->(workflow_id) { where(workflow_id: workflow_id) if workflow_id.present? }
  scope :for_run, ->(run_id) { where(run_id: run_id) if run_id.present? }

  def anchor_key
    [
      side,
      old_line || "",
      new_line || ""
    ].join(":")
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
    self.path = path.to_s.strip
    self.side = side.to_s.strip
    self.body = body.to_s.strip
    self.diff_hunk = diff_hunk.to_s.presence
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

  def stamp_lifecycle_transition
    now = Time.current
    self.submitted_at ||= now if state == "submitted"
    self.resolved_at ||= now if state == "resolved"
    self.superseded_at ||= now if state == "superseded"
  end
end
