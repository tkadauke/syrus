module ReviewPlanning
  # Resolves whether the repository's default-branch `.syrus.yml` opts into
  # review planning, so the chain can decide whether to materialize the step
  # at all instead of creating one that skips itself.
  class Plan
    Result = Data.define(:enabled, :source, :note) do
      def enabled? = enabled
    end

    def self.for_job(job)
      from_syrus_yml(RepoDefaultBranchSyrusYml.for_job(job))
    end

    def self.from_syrus_yml(loaded)
      return disabled(source: loaded.source, note: loaded.note) unless loaded.config

      value = loaded.config.plugin_configurations[ReviewPlanning::RepositoryConfiguration::KEY]
      Result.new(enabled: value == true, source: loaded.source, note: nil)
    end

    def self.disabled(source:, note:)
      Result.new(enabled: false, source: source, note: note)
    end
  end
end
