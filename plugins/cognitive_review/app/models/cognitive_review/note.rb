require "digest"

module CognitiveReview
  class Note < ApplicationRecord
    self.table_name = "cognitive_review_notes"

    SIDES = %w[new old].freeze
    STATES = %w[open acknowledged discussed dismissed].freeze
    PRIORITIES = %w[low medium high].freeze
    COMMENT_SIDE_BY_NOTE_SIDE = {
      "new" => "right",
      "old" => "left"
    }.freeze
    COMMENT_LINE_METHOD_BY_NOTE_SIDE = {
      "new" => :new_line,
      "old" => :old_line
    }.freeze

    belongs_to :job
    belongs_to :workflow
    belongs_to :run
    belongs_to :diff_review_version
    belongs_to :acknowledged_by_user, class_name: "User", optional: true
    belongs_to :discussion_started_by_user, class_name: "User", optional: true
    belongs_to :last_discussed_by_user, class_name: "User", optional: true
    has_many :discussion_entries,
      class_name: "CognitiveReview::DiscussionEntry",
      foreign_key: :note_id,
      inverse_of: :note,
      dependent: :destroy

    attribute :reason_codes, :json, default: -> { [] }
    attribute :source_metadata, :json, default: -> { {} }

    before_validation :normalize_fields
    before_validation :derive_side_range
    before_validation :assign_idempotency_key

    validates :path, :title, :explanation, :idempotency_key, presence: true
    validates :side, presence: true, inclusion: { in: SIDES }
    validates :state, presence: true, inclusion: { in: STATES }
    validates :priority, presence: true, inclusion: { in: PRIORITIES }
    validates :start_line, :end_line, numericality: { only_integer: true, greater_than: 0 }
    validates :confidence, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }, allow_nil: true
    validates :idempotency_key, uniqueness: { scope: %i[run_id diff_review_version_id] }
    validate :end_line_not_before_start_line
    validate :side_specific_range_present
    validate :graph_belongs_to_job
    validate :run_belongs_to_workflow
    validate :reason_codes_array
    validate :source_metadata_hash

    scope :ordered, -> { order(:path, :side, :start_line, :end_line, :id) }
    scope :for_diff_review_version, ->(version_id) { where(diff_review_version_id: version_id) if version_id.present? }
    scope :for_path, ->(path) { where(path: path) if path.present? }
    scope :for_state, ->(state) { where(state: state) if state.present? }
    scope :open_debt, -> { where(state: "open") }
    scope :handled, -> { where(state: %w[acknowledged discussed]) }
    scope :dismissed, -> { where(state: "dismissed") }

    def self.review_comments_for(notes, diff_review_version_ids: [])
      note_records = Array(notes)
      version_ids = (note_records.filter_map(&:diff_review_version_id) + Array(diff_review_version_ids)).compact.uniq
      return DiffReviewComment.none if note_records.empty? || version_ids.empty?

      DiffReviewComment
        .where(job_id: note_records.map(&:job_id).uniq, diff_review_version_id: version_ids, anchor_kind: "line")
        .where.not(state: "superseded")
    end

    def self.open_for_pr_debt(notes, review_comments: review_comments_for(notes), diff_review_version_ids: [])
      comment_records = review_comments.to_a
      Array(notes).select { |note| note.open_for_pr_debt?(review_comments: comment_records, diff_review_version_ids: diff_review_version_ids) }
    end

    def self.handled_for_pr_debt(notes, review_comments: review_comments_for(notes), diff_review_version_ids: [])
      comment_records = review_comments.to_a
      Array(notes).select { |note| note.handled_for_pr_debt?(review_comments: comment_records, diff_review_version_ids: diff_review_version_ids) }
    end

    def self.upsert_from_submission!(run:, diff_review_version:, attributes:)
      attrs = attributes.with_indifferent_access
      workflow = run.workflow
      raise ArgumentError, "run must belong to a workflow" unless workflow
      raise ArgumentError, "diff review version is required" unless diff_review_version

      note = find_or_initialize_by(
        run: run,
        diff_review_version: diff_review_version,
        idempotency_key: idempotency_key_for(attrs)
      )
      note.assign_attributes(
        job: run.job,
        workflow: workflow,
        path: attrs[:path],
        side: attrs[:side],
        start_line: attrs[:start_line],
        end_line: attrs[:end_line],
        title: attrs[:title],
        summary: attrs[:summary],
        explanation: attrs[:explanation],
        reason_codes: attrs[:reason_codes],
        confidence: attrs[:confidence],
        priority: attrs[:priority],
        source_metadata: attrs[:source_metadata],
        state: note.state.presence || "open"
      )
      note.save!
      note
    end

    def self.idempotency_key_for(attributes)
      attrs = attributes.with_indifferent_access
      seed = [
        attrs[:path],
        attrs[:side],
        attrs[:start_line],
        attrs[:end_line],
        attrs[:title],
        Array(attrs[:reason_codes]).join(",")
      ].join("\0")
      Digest::SHA256.hexdigest(seed)
    end

    def acknowledge!(user:)
      with_lock do
        return false unless state == "open"

        update!(
          state: "acknowledged",
          acknowledged_at: Time.current,
          acknowledged_by_user: user
        )
        true
      end
    end

    def add_discussion_entry!(user:, body:, metadata: {})
      with_lock do
        entry = discussion_entries.create!(user: user, body: body, metadata: metadata)
        timestamp = entry.created_at || Time.current
        update!(
          state: "discussed",
          discussion_started_at: discussion_started_at || timestamp,
          discussion_started_by_user: discussion_started_by_user || user,
          last_discussed_at: timestamp,
          last_discussed_by_user: user
        )
        entry
      end
    end

    def open? = state == "open"
    def handled? = %w[acknowledged discussed].include?(state)
    def open_for_pr_debt?(review_comments:, diff_review_version_ids: []) = open? && !covered_by_user_comment?(review_comments, diff_review_version_ids: diff_review_version_ids)
    def handled_for_pr_debt?(review_comments:, diff_review_version_ids: []) = handled? || covered_by_user_comment?(review_comments, diff_review_version_ids: diff_review_version_ids)

    def covered_by_user_comment?(review_comments, diff_review_version_ids: [])
      allowed_version_ids = ([ diff_review_version_id ] + Array(diff_review_version_ids)).compact.uniq
      Array(review_comments).any? { |comment| covered_by_user_comment_range?(comment, diff_review_version_ids: allowed_version_ids) }
    end

    private

    def normalize_fields
      self.path = path.to_s.strip
      self.side = side.to_s.strip
      self.title = title.to_s.strip
      self.summary = summary.to_s.strip.presence
      self.explanation = explanation.to_s.strip
      self.priority = priority.to_s.strip.presence || "medium"
      self.reason_codes = Array(reason_codes).map { |code| code.to_s.strip }.reject(&:blank?).uniq
      self.source_metadata = {} unless source_metadata.is_a?(Hash)
      self.state = state.to_s.strip.presence || "open"
    end

    def covered_by_user_comment_range?(comment, diff_review_version_ids:)
      return false unless diff_review_version_ids.include?(comment.diff_review_version_id)
      return false unless comment.path == path
      return false unless comment.side == COMMENT_SIDE_BY_NOTE_SIDE[side]

      comment_line = comment.public_send(COMMENT_LINE_METHOD_BY_NOTE_SIDE[side])
      comment_line.present? && comment_line.between?(start_line, end_line)
    end

    def derive_side_range
      return unless SIDES.include?(side)

      normalized_start = Integer(start_line, exception: false)
      normalized_end = Integer(end_line, exception: false) || normalized_start
      self.start_line = [ normalized_start, normalized_end ].compact.min
      self.end_line = [ normalized_start, normalized_end ].compact.max
      if side == "new"
        self.new_start_line = start_line
        self.new_end_line = end_line
      else
        self.old_start_line = start_line
        self.old_end_line = end_line
      end
    end

    def assign_idempotency_key
      self.idempotency_key = self.class.idempotency_key_for(attributes) if idempotency_key.blank?
    end

    def end_line_not_before_start_line
      return if start_line.blank? || end_line.blank? || end_line >= start_line

      errors.add(:end_line, "must be greater than or equal to start_line")
    end

    def side_specific_range_present
      return if side == "new" && new_start_line.present? && new_end_line.present?
      return if side == "old" && old_start_line.present? && old_end_line.present?
      return unless SIDES.include?(side)

      errors.add(:base, "#{side}-side notes require #{side}_start_line and #{side}_end_line")
    end

    def graph_belongs_to_job
      errors.add(:workflow, "must belong to the same job") if workflow && job_id && workflow.job_id != job_id
      errors.add(:run, "must belong to the same job") if run && job_id && run.job_id != job_id
      errors.add(:diff_review_version, "must belong to the same job") if diff_review_version && job_id && diff_review_version.job_id != job_id
    end

    def run_belongs_to_workflow
      return unless run && workflow && run.workflow_id != workflow.id

      errors.add(:run, "must belong to the same workflow")
    end

    def reason_codes_array
      errors.add(:reason_codes, "must be an array") unless reason_codes.is_a?(Array)
    end

    def source_metadata_hash
      errors.add(:source_metadata, "must be an object") unless source_metadata.is_a?(Hash)
    end
  end
end
