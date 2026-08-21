module JavaScript
  # :review_criteria_provider seeding a default adversarial-review checklist
  # item for JS/TS code: a newly introduced `any` type defeats the type
  # checker exactly where it matters most (new code), and is easy for a
  # reviewer to grep the diff for.
  class ReviewCriteriaProvider
    def self.criteria(repo_path)
      return [] unless JavaScript::PrepareDetector.detect?(repo_path)

      [ "Flag newly introduced `any` types" ]
    end
  end
end
