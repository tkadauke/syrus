module SkillJobs
  # Creates a `direct` Job that launches a named Skills:: instruction set
  # (EPIC-233's "launch a skill by name + args" entry point) instead of a
  # free-form prompt. Validates the skill actually resolves and the
  # supplied args satisfy its declared parameter schema before creating
  # anything, so a bad launch request never reaches the Workflow
  # pipeline. `Job#create_initial_run` reads `skill_name`/`skill_args`
  # off the created Job to build a `Workflows::Skill` (trigger_kind
  # "skill") instead of `Workflows::Initial`.
  class Creator
    Result = Data.define(:job, :error) do
      def success? = error.nil?
    end

    def self.call(...) = new(...).call

    def initialize(user:, repository:, name:, args: {}, agent_provider: nil, priority: nil, epic: nil, delivery_track: nil)
      @user = user
      @repository = repository
      @name = name.to_s.strip
      @args = args || {}
      @agent_provider = agent_provider.to_s.presence
      @priority = priority.to_s.presence
      @epic = epic
      @delivery_track = delivery_track.to_s.presence
    end

    def call
      resolution = resolve_skill
      return failure(resolution) if resolution.is_a?(String)

      Skills::ParameterSchema.validate!(resolution.definition.parameters, @args)

      job = create_job!(resolution.definition)
      job.advance_after_triage! if job.may_advance_after_triage?
      Result.new(job: job.reload, error: nil)
    rescue Skills::ParameterSchema::ValidationError => e
      failure(e.message)
    end

    private

    def resolve_skill
      raise ArgumentError, "name is required" if @name.blank?

      Skills.for(repository: @repository, name: @name, user: @user)
    rescue Skills::NotFoundError, ArgumentError, Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError => e
      "could not resolve skill #{@name.inspect}: #{e.message}"
    end

    def failure(message)
      Result.new(job: nil, error: message)
    end

    def create_job!(definition)
      @user.jobs.create!(
        repository: @repository,
        kind: "direct",
        skill_name: @name,
        skill_args: @args,
        issue_number: nil,
        issue_title: "Skill: #{@name}",
        title_pending: false,
        issue_body: Skills::Renderer.render(definition, @args),
        epic: @epic,
        agent_provider: @agent_provider || @repository.effective_agent_provider,
        job_provider_setting: @agent_provider || "default",
        priority: Job::PRIORITIES.include?(@priority) ? @priority : "medium",
        delivery_track: @delivery_track,
        state: Job.initial_state_for_creator(@user)
      )
    end
  end
end
