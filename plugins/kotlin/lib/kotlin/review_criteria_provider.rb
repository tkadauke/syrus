module Kotlin
  # :review_criteria_provider seeding Kotlin/JVM-specific checklist items for
  # common coroutine and null-safety hazards.
  class ReviewCriteriaProvider
    CRITERIA = [
      "Flag swallowed CancellationException or broad coroutine exception handling that prevents cooperative cancellation",
      "Flag unsafe Kotlin null assertions (`!!`) on data from external boundaries"
    ].freeze

    def self.criteria(repo_path)
      return [] unless Kotlin::PrepareDetector.detect?(repo_path)

      CRITERIA
    end
  end
end
