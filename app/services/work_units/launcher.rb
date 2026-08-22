module WorkUnits
  class Launcher
    def self.instantiate(kind:, job:, artifacts: nil, agent_provider: nil, **options)
      new(
        kind: kind,
        job: job,
        artifacts: artifacts,
        agent_provider: agent_provider,
        options: options
      ).instantiate
    end

    def initialize(kind:, job:, artifacts:, agent_provider:, options:)
      @definition = WorkDefinitions.for(kind)
      @job = job
      @artifacts = artifacts
      @agent_provider = agent_provider
      @options = options
    end

    def instantiate
      definition.workflow_template.instantiate(**instantiate_arguments)
    end

    private

    attr_reader :definition, :job, :artifacts, :agent_provider, :options

    def instantiate_arguments
      {
        job: job,
        artifacts: artifacts,
        agent_provider: agent_provider
      }.merge(options)
    end
  end
end
