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
      WorkIntent.transaction do
        intent = create_intent!
        unit = create_unit!(intent)
        workflow = definition.workflow_template.instantiate(**instantiate_arguments)
        unit.update!(workflow: workflow)
        create_members!(unit)
        workflow
      end
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

    def create_intent!
      WorkIntent.create!(
        kind: definition.kind,
        state: "requested",
        repository: job.repository,
        scope_type: scope_type,
        scope_id: scope_id,
        priority: job.priority,
        actor: job.user,
        source_type: "workflow_launch"
      )
    end

    def create_unit!(intent)
      WorkUnit.create!(
        work_intent: intent,
        kind: definition.kind,
        state: "queued",
        repository: job.repository,
        scope_type: scope_type,
        scope_id: scope_id
      )
    end

    def create_members!(unit)
      member_jobs.each_with_index do |member_job, index|
        unit.work_unit_members.create!(
          job: member_job,
          role: index.zero? ? "primary" : "member"
        )
      end
    end

    def scope_type
      definition.scope
    end

    def scope_id
      case definition.scope
      when "job"
        job.id
      when "epic"
        job.epic_id
      when "repository"
        job.repository_id
      else
        job.id
      end
    end

    def member_jobs
      [ job ]
    end
  end
end
