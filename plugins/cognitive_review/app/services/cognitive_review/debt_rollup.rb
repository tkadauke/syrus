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
        zero_note_state: zero_note_state?
      }
    end

    def total_flagged_ranges = counts.values.sum
    def open_unhandled_count = counts.fetch("open", 0)
    def acknowledged_count = counts.fetch("acknowledged", 0)
    def discussed_count = counts.fetch("discussed", 0)
    def dismissed_count = counts.fetch("dismissed", 0)
    def handled_count = acknowledged_count + discussed_count
    def zero_note_state? = total_flagged_ranges.zero?

    private

    def counts
      @counts ||= begin
        if @notes
          @notes.to_a.map(&:state).tally
        elsif diff_review_version
          CognitiveReview::Note.where(job: job, diff_review_version: diff_review_version).group(:state).count
        else
          {}
        end
      end
    end
  end
end
