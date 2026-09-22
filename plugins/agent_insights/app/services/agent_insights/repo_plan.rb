module AgentInsights
  class RepoPlan
    CONFIG_FILE = SyrusYml::CONFIG_FILE

    Result = Data.define(:prepare, :source, :note) do
      def prepare?
        prepare == true
      end
    end

    def self.for_job(job)
      new(repository: job.repository, user: job.user).resolve
    end

    def initialize(repository:, user:)
      @repository = repository
      @user = user
    end

    def resolve
      loaded = RepoDefaultBranchSyrusYml.new(repository: repository, user: user).resolve
      return default(source: loaded.source, note: loaded.note) unless loaded.loaded?

      insight = loaded.config.agent_insight
      return default(source: ".syrus.yml", note: "no agent_insight configured") unless insight

      Result.new(prepare: insight.prepare, source: ".syrus.yml", note: nil)
    end

    private

    attr_reader :repository, :user

    def default(source: "none", note:)
      Result.new(prepare: false, source: source, note: note)
    end
  end
end
