class AutoApprovalRule
  Result = Data.define(:approved, :reason, :mode, :source) do
    def approved? = approved
  end

  GRADER_FILES = [ ".syrus.yml", ".syrus/graders" ].freeze

  class Mode
    def self.for(name, rule:, source:)
      {
        "never" => Never,
        "if_graders_pass" => IfGradersPass,
        "if_graders_pass_and_tagged_safe" => IfGradersPassAndTaggedSafe
      }.fetch(name).new(name: name, rule: rule, source: source)
    end

    def initialize(name:, rule:, source:)
      @name = name
      @rule = rule
      @source = source
    end

    private

    attr_reader :name, :rule, :source

    def reject(reason)
      Result.new(approved: false, reason: reason, mode: name, source: source)
    end
  end

  class Never < Mode
    def apply_after_grader_success!(_grader_step)
      Result.new(approved: false, reason: "no_matching_rule", mode: "never", source: nil)
    end
  end

  class IfGradersPass < Mode
    def apply_after_grader_success!(grader_step)
      return reject("grader_not_repo_committed") unless rule.repo_committed_grader?(grader_step)

      rule.approve_after_grader_success!(mode: name, source: source, grader_step: grader_step)
    end
  end

  class IfGradersPassAndTaggedSafe < IfGradersPass
    def apply_after_grader_success!(grader_step)
      return reject("safe_tag_missing") unless rule.safe_tagged?

      super
    end
  end

  def self.for(job)
    new(job)
  end

  def initialize(job)
    @job = job
  end

  def apply_after_grader_success!(grader_step)
    mode, source = resolved_mode

    Mode.for(mode, rule: self, source: source).apply_after_grader_success!(grader_step)
  end

  def approve_after_grader_success!(mode:, source:, grader_step:)
    @job.with_lock do
      @job.reload
      @job.mark_implemented! if @job.may_mark_implemented?
      return Result.new(approved: false, reason: "job_not_approvable", mode: mode, source: source) unless @job.may_approve?

      @job.approve!(
        via: "auto_rule",
        evidence: {
          "rule" => mode,
          "source" => source,
          "grader_step_id" => grader_step.id
        }
      )
    end

    # Dispatch the AutoMerge workflow inline instead of relying on
    # the next LandingQueueProcessor tick (or worse, leaving the Job
    # stuck in :landing with no workflow as the previous
    # `@job.land!` did — land! transitioned state but never
    # instantiated the workflow, jamming the queue). try_land! runs
    # the same guards LandingQueueProcessor's loop uses; if a
    # blockage is present (another Job currently landing, etc.) the
    # enqueued LandingQueueProcessorJob from approve!'s state-change
    # callback will pick it up on its tick.
    LandingQueueProcessor.try_land!(@job)

    audit!("auto_approval: approved via #{mode} from #{source} after grader step ##{grader_step.id}")
    Result.new(approved: true, reason: nil, mode: mode, source: source)
  end

  def resolved_mode
    candidates = []
    candidates << [ @job.scheduled_task&.auto_approve_mode, "ScheduledTask##{@job.scheduled_task_id}" ] if @job.cron?
    candidates << [ @job.epic&.auto_approve_mode, "Epic##{@job.epic.number}" ] if @job.epic_id
    candidates << [ @job.repository.auto_approve_mode, "Repository##{@job.repository_id}" ]
    candidates << [ @job.user.auto_approve_mode, "User##{@job.user_id}" ]

    candidates.each do |mode, source|
      next if mode.blank? || mode == "never"
      return [ mode, source ]
    end

    [ "never", nil ]
  end

  def safe_tagged?
    @job.tags.where("LOWER(tags.name) = ?", "safe").exists?
  end

  def repo_committed_grader?(grader_step)
    workflow = grader_step.workflow
    workflow.artifact("grade_plan_source").present? &&
      workflow.artifact("grade_plan_source") != "none" &&
      workflow.artifact("grade_plan_repo_committed") == true
  end

  private

  def audit!(message)
    run = @job.current_run
    return unless run

    JobLog.append!(run: run, chunk: message, kind: "system")
  end
end
