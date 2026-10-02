module CognitiveReview
  class DebtRollup
    COMMENT_STATES_THAT_HANDLE_NOTES = %w[draft submitted resolved].freeze
    COMMENT_SIDE_FOR_NOTE_SIDE = {
      "old" => "left",
      "new" => "right"
    }.freeze
    COMMENT_LINE_READER_FOR_NOTE_SIDE = {
      "old" => :old_line,
      "new" => :new_line
    }.freeze

    attr_reader :job, :diff_review_version

    def self.for(job:, diff_review_version:, notes: nil)
      new(job: job, diff_review_version: diff_review_version, notes: notes)
    end

    def initialize(job:, diff_review_version:, notes: nil)
      @job = job
      @diff_review_version = diff_review_version
      @notes = notes
    end

    def as_json(*)
      {
        total_flagged_ranges: total_flagged_ranges,
        open_unhandled_count: open_unhandled_count,
        acknowledged_count: acknowledged_count,
        discussed_count: discussed_count,
        user_commented_count: user_commented_count,
        dismissed_count: dismissed_count,
        handled_count: handled_count,
        submitted: submitted?,
        zero_note_state: zero_note_state?
      }
    end

    def total_flagged_ranges = notes.size
    def open_unhandled_count = [ counts.fetch("open", 0) - user_commented_count, 0 ].max
    def acknowledged_count = counts.fetch("acknowledged", 0)
    def discussed_count = counts.fetch("discussed", 0)
    def user_commented_count = user_commented_open_notes.size
    def dismissed_count = counts.fetch("dismissed", 0)
    def handled_count = acknowledged_count + discussed_count + user_commented_count
    def submitted? = total_flagged_ranges.positive? || submission_entry.present?
    def zero_note_state? = submitted? && total_flagged_ranges.zero?
    def user_commented?(note) = user_commented_open_notes.include?(note)

    private

    def notes
      @note_records ||= if @notes
        @notes.to_a
      elsif diff_review_version
        CognitiveReview::Note.where(job: job, diff_review_version: diff_review_version).to_a
      else
        []
      end
    end

    def counts
      @counts ||= notes.map(&:state).tally
    end

    def user_commented_open_notes
      @user_commented_open_notes ||= open_notes.select do |note|
        covering_user_comments.any? { |comment| comment_covers_note?(comment, note) }
      end
    end

    def open_notes
      notes.select { |note| note.state == "open" }
    end

    def covering_user_comments
      @covering_user_comments ||= CognitiveReview::Note
        .review_comments_for(notes)
        .where(state: COMMENT_STATES_THAT_HANDLE_NOTES)
        .to_a
    end

    def comment_covers_note?(comment, note)
      expected_side = COMMENT_SIDE_FOR_NOTE_SIDE[note.side]
      line_reader = COMMENT_LINE_READER_FOR_NOTE_SIDE[note.side]
      return false unless expected_side && line_reader
      return false unless comment.path == note.path && comment.side == expected_side

      line = comment.public_send(line_reader)
      line.present? && line >= note.start_line && line <= note.end_line
    end

    def submission_entry
      @submission_entry ||= if diff_review_version
        CognitiveReview::Artifact.matching_entry_for(
          job: job,
          version: diff_review_version,
          base_sha: nil,
          head_sha: nil
        )
      end
    end
  end
end
