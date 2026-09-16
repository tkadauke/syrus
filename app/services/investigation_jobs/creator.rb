module InvestigationJobs
  # Creates a `direct` Job flagged investigation-only (no PR expected)
  # instead of a normal free-form implementation prompt. Mirrors
  # SkillJobs::Creator's shape: `Job#create_initial_run` reads
  # `investigation` off the created Job to build a `Workflows::Investigation`
  # (trigger_kind "investigation") instead of `Workflows::Initial`.
  class Creator
    Result = Data.define(:job, :error) do
      def success? = error.nil?
    end

    def self.call(...) = new(...).call

    def initialize(user:, repository:, prompt:, agent_provider: nil, priority: nil, epic: nil, delivery_track: nil)
      @user = user
      @repository = repository
      @prompt = prompt.to_s.strip
      @agent_provider = agent_provider.to_s.presence
      @priority = priority.to_s.presence
      @epic = epic
      @delivery_track = delivery_track.to_s.presence
    end

    def call
      return failure("prompt is required") if @prompt.blank?

      job = create_job!
      job.advance_after_triage! if job.may_advance_after_triage?
      Result.new(job: job.reload, error: nil)
    end

    private

    def failure(message)
      Result.new(job: nil, error: message)
    end

    def create_job!
      @user.jobs.create!(
        repository: @repository,
        kind: "direct",
        investigation: true,
        issue_number: nil,
        issue_title: "Investigation: #{@prompt.truncate(80)}",
        title_pending: false,
        issue_body: @prompt,
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
