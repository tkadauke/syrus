module Ruby
  # :review_criteria_provider seeding a default adversarial-review checklist
  # item for ActiveRecord code: N+1 query patterns are a common, easy to miss
  # regression that a reviewer with full tool access can actually check for.
  class ReviewCriteriaProvider
    def self.criteria(repo_path)
      return [] unless Ruby::PrepareDetector.detect?(repo_path)

      [ "Flag new N+1 query patterns in ActiveRecord code" ]
    end
  end
end
