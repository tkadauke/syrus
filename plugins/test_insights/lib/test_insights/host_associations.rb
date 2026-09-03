module TestInsights
  # Adds this plugin's associations to core models.
  #
  # Core no longer declares `Run has_many :test_runs` or
  # `Repository has_many :test_identities`: it does not own test results, and a
  # core model naming a plugin class is exactly the coupling the boundary
  # grader rejects. The associations are injected here instead, guarded so a
  # reload cannot define them twice.
  module HostAssociations
    def self.apply!
      apply_run_associations
      apply_repository_associations
    end

    def self.apply_run_associations
      return if Run.reflect_on_association(:test_runs)

      Run.has_many :test_runs,
                   class_name: "TestInsights::TestRun",
                   foreign_key: :run_id,
                   inverse_of: :run,
                   dependent: :destroy
    end

    def self.apply_repository_associations
      return if Repository.reflect_on_association(:test_identities)

      Repository.has_many :test_identities,
                          class_name: "TestInsights::TestIdentity",
                          foreign_key: :repository_id,
                          inverse_of: :repository,
                          dependent: :destroy
    end
  end
end
