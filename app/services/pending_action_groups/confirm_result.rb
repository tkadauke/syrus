module PendingActionGroups
  ConfirmResult = Data.define(:group, :member_results) do
    def successes = member_results.select(&:success?)
    def failures = member_results.select(&:failure?)
    def applied = member_results.select { |result| result.outcome == "applied" }
    def skipped_or_ineligible = member_results.select { |result| result.outcome == "skipped" }
    def failed = member_results.select { |result| result.outcome == "failed" }
    def all_succeeded? = failures.empty?
    def any_failed? = failures.any?
  end
end
