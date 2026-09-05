module PendingActionGroups
  ConfirmResult = Data.define(:group, :member_results) do
    def successes = member_results.select(&:success?)
    def failures = member_results.select(&:failure?)
    def all_succeeded? = failures.empty?
    def any_failed? = failures.any?
  end
end
