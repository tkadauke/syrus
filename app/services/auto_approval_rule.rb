class AutoApprovalRule
  Result = Data.define(:approved, :reason, :mode, :source) do
    def approved? = approved
  end

  GRADER_FILES = [ ".syrus.yml", ".syrus/graders" ].freeze

  def self.for(job)
    new(job)
  end

  def initialize(job)
    @job = job
  end

  def apply_after_grader_success!(grader_step)
    mode, source = resolved_mode
    return Result.new(approved: false, reason: "no_matching_rule", mode: "never", source: nil) if mode == "never"
    return Result.new(approved: false, reason: "safe_tag_missing", mode: mode, source: source) if mode == "if_graders_pass_and_tagged_safe" && !safe_tagged?
    return Result.new(approved: false, reason: "grader_not_repo_committed", mode: mode, source: source) unless repo_committed_grader?(grader_step)

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
      @job.land! if @job.may_land?
    end

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

  private

  def safe_tagged?
    @job.tags.where("LOWER(tags.name) = ?", "safe").exists?
  end

  def repo_committed_grader?(grader_step)
    workflow = grader_step.workflow
    workflow.artifact("grade_plan_source").present? &&
      workflow.artifact("grade_plan_source") != "none" &&
      workflow.artifact("grade_plan_repo_committed") == true
  end

  def audit!(message)
    run = @job.current_run
    return unless run

    run.job_logs.create!(
      chunk: message,
      sequence: (run.job_logs.maximum(:sequence) || -1) + 1,
      kind: "system"
    )
  end
end
