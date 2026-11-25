module TestInsights
  # Bounded, resumable denormalization of TestRun#grader_name onto TestCase.
  # Live ingestion fills new rows, while runtime reads retain their join-based
  # compatibility path until the recent window for an identity is complete.
  class GraderNameBackfill
    Result = Struct.new(:done, :processed, :next_after_id, keyword_init: true)

    def self.pending_count(after_id: 0, up_to_id: nil) = new.pending_count(after_id: after_id, up_to_id: up_to_id)
    def self.max_test_case_id = TestCase.maximum(:id).to_i

    def self.pending_in_range?(after_id: 0, up_to_id: nil) = new.pending_in_range?(after_id: after_id, up_to_id: up_to_id)

    # Exact, and therefore a full scan of every unfilled case joined to its
    # run: on production history that took about sixteen minutes. Never call
    # it from anything that runs routinely.
    def pending_count(after_id: 0, up_to_id: nil)
      candidates(after_id, up_to_id).count
    end

    # Whether any unfilled case remains in the range: a primary-key walk that
    # stops at the first hit, with no join.
    def pending_in_range?(after_id: 0, up_to_id: nil)
      scope = TestCase.where(grader_name: nil).where("test_insight_cases.id > ?", after_id)
      scope = scope.where("test_insight_cases.id <= ?", up_to_id) if up_to_id.present?
      scope.exists?
    end

    def call(after_id: 0, up_to_id: nil, limit:)
      rows = candidates(after_id, up_to_id).limit(limit).pluck("test_insight_cases.id", "test_insight_runs.grader_name")
      return Result.new(done: true, processed: 0, next_after_id: up_to_id || after_id) if rows.empty?

      now = Time.current
      rows.group_by(&:second).each do |grader_name, grader_rows|
        TestCase.where(id: grader_rows.map(&:first), grader_name: nil).update_all(grader_name: grader_name, updated_at: now)
      end

      Result.new(done: false, processed: rows.size, next_after_id: rows.last.first)
    end

    private

    def candidates(after_id, up_to_id)
      scope = TestCase
        .joins(:test_run)
        .where(grader_name: nil)
        .where("test_insight_cases.id > ?", after_id)
        .order("test_insight_cases.id ASC")
      up_to_id.present? ? scope.where("test_insight_cases.id <= ?", up_to_id) : scope
    end
  end
end
