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

    # One batch covers a window of `limit` consecutive case ids, starting at
    # the next case that exists. Taking "the next `limit` unfilled cases"
    # instead needed `ORDER BY id LIMIT n` across the join, which MySQL
    # planned from test_insight_runs with a temporary table and a filesort
    # over every unfilled case: a single 500-row batch ran for minutes on
    # production. A primary-key window is a range scan plus an eq_ref
    # lookup of each case's run, however much history there is.
    def call(after_id: 0, up_to_id: nil, limit:)
      start_id = next_case_id(after_id, up_to_id)
      return Result.new(done: true, processed: 0, next_after_id: up_to_id || after_id) unless start_id

      window_end = start_id + limit - 1
      window_end = [ window_end, up_to_id ].min if up_to_id.present?
      rows = TestCase.joins(:test_run).where(grader_name: nil, id: start_id..window_end)
                     .pluck("test_insight_cases.id", "test_insight_runs.grader_name")

      now = Time.current
      rows.reject { |_, grader_name| grader_name.nil? }.group_by(&:second).each do |grader_name, grader_rows|
        TestCase.where(id: grader_rows.map(&:first), grader_name: nil).update_all(grader_name: grader_name, updated_at: now)
      end

      Result.new(done: false, processed: rows.size, next_after_id: window_end)
    end

    private

    # The next existing case id: a primary-key seek, so gaps in the id space
    # (deleted history) cost one query, not a batch per empty window.
    def next_case_id(after_id, up_to_id)
      scope = TestCase.where("test_insight_cases.id > ?", after_id)
      scope = scope.where("test_insight_cases.id <= ?", up_to_id) if up_to_id.present?
      scope.minimum(:id)
    end

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
