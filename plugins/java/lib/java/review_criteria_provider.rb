module Java
  # :review_criteria_provider seeding a default adversarial-review checklist
  # item for Java/JVM code: interrupted threads must restore their interrupted
  # status or propagate the interruption so callers can stop cleanly.
  class ReviewCriteriaProvider
    def self.criteria(repo_path)
      return [] unless Java::PrepareDetector.detect?(repo_path)

      [ "Flag swallowed InterruptedException without restoring interrupt status" ]
    end
  end
end
