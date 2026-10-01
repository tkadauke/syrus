module CognitiveReview
  class DebtRollup
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
        dismissed_count: dismissed_count,
        handled_count: handled_count,
        submitted: submitted?,
        zero_note_state: zero_note_state?
      }
    end

    def total_flagged_ranges = notes.size
    def open_unhandled_count = CognitiveReview::Note.open_for_pr_debt(notes, review_comments: review_comments).size
    def acknowledged_count = counts.fetch("acknowledged", 0)
    def discussed_count = counts.fetch("discussed", 0)
    def dismissed_count = counts.fetch("dismissed", 0)
    def handled_count = CognitiveReview::Note.handled_for_pr_debt(notes, review_comments: review_comments).size
    def submitted? = total_flagged_ranges.positive? || submission_entry.present?
    def zero_note_state? = submitted? && total_flagged_ranges.zero?

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

    def review_comments
      @review_comments ||= CognitiveReview::Note.review_comments_for(notes).to_a
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
