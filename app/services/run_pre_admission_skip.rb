class RunPreAdmissionSkip
  Result = Data.define(:skip, :reason, :message, :artifacts) do
    def skip? = skip
  end

  VISUAL_REVIEW_PREFILTER_MESSAGE =
    "No changed files matched the configured visual_review.when_files_changed patterns.".freeze

  def self.call(...) = new(...).call

  def initialize(run:)
    @run = run
    @step = run&.step
    @workflow = @step&.workflow
    @job = run&.job
  end

  def call
    return pass unless queued_execution_graph?
    return pass unless workspace_ready?

    policy_for_step.call
  end

  private

  POLICIES = {
    "review_plan" => "RunPreAdmissionSkip::ReviewPlan",
    "visual_review" => "RunPreAdmissionSkip::VisualReview"
  }.freeze

  attr_reader :run, :step, :workflow, :job

  def queued_execution_graph?
    run&.queued? && step&.queued? && workflow && !workflow.terminal?
  end

  def workspace_ready?
    workspace_path.directory? && workspace_path.join(".git").directory?
  end

  def workspace_path
    @workspace_path ||= WorkflowWorkspace.path_for(workflow)
  end

  def policy_for_step
    policy_class = POLICIES.fetch(step.kind, RunPreAdmissionSkip::Base)
    policy_class = policy_class.constantize if policy_class.is_a?(String)
    policy_class.new(run: run, step: step, workflow: workflow, job: job, workspace_path: workspace_path)
  end

  def pass
    Result.new(skip: false, reason: nil, message: nil, artifacts: {})
  end

  class Base
    def initialize(run:, step:, workflow:, job:, workspace_path:)
      @run = run
      @step = step
      @workflow = workflow
      @job = job
      @workspace_path = workspace_path
    end

    def call
      pass
    end

    private

    attr_reader :run, :step, :workflow, :job, :workspace_path

    def skip(reason, message, artifacts = {})
      Result.new(skip: true, reason: reason, message: message, artifacts: artifacts)
    end

    def pass
      Result.new(skip: false, reason: nil, message: nil, artifacts: {})
    end
  end

  class ReviewPlan < Base
    def call
      config_path = workspace_path.join(SyrusYml::CONFIG_FILE)
      return skip("review_plan_not_configured", "[review_plan] not configured in .syrus.yml - skipping") unless config_path.exist?

      if SyrusYml.load_repo(workspace_path).review_plan
        pass
      else
        skip("review_plan_not_configured", "[review_plan] not configured in .syrus.yml - skipping")
      end
    rescue SyrusYml::ParseError => e
      skip("review_plan_parse_error", "[review_plan] .syrus.yml parse error: #{e.message}")
    end
  end

  class VisualReview < Base
    def call
      config = SyrusYml.load_repo(workspace_path).visual_review
      patterns = Array(config&.when_files_changed)
      return pass if patterns.empty?
      return pass if changed_files.any? { |file| patterns.any? { |pattern| File.fnmatch(pattern, file, File::FNM_DOTMATCH) } }

      iterations = Array(workflow.artifact("visual_review_iterations"))
      skip(
        "visual_review_when_files_changed_no_match",
        "[visual_review] skipped: no changed files match visual_review.when_files_changed",
        "visual_review_iterations" => iterations + [
          {
            "iteration" => step.iteration,
            "critique" => VISUAL_REVIEW_PREFILTER_MESSAGE,
            "verdict" => "skipped"
          }
        ]
      )
    rescue SyrusYml::ParseError, Errno::ENOENT, GitRunner::GitError
      pass
    end

    private

    def changed_files
      GitRunner.new.run(
        "diff", "--name-only", "#{WorkflowWorkspace.base_ref_for(job, workflow: workflow)}...HEAD",
        chdir: workspace_path.to_s
      ).split("\n").map(&:strip).reject(&:empty?)
    end
  end
end
