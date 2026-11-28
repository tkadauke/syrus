class MainBranchRepairAutoApprover
  Result = Data.define(:approved, :reason) do
    def approved? = approved
  end

  def self.call(job)
    new(job).call
  end

  def initialize(job)
    @job = job
  end

  def call
    return skipped("not_main_branch_repair") unless @job.main_branch_repair?
    return skipped("setting_disabled") unless @job.repository.main_branch_repair_auto_approve?

    approved = false
    reason = nil

    @job.with_lock do
      @job.reload(lock: true)
      if !@job.implemented?
        reason = "not_implemented"
      elsif !@job.may_approve?
        reason = "not_approvable"
      else
        @job.approve!(
          via: "auto_rule",
          evidence: {
            "rule" => "main_branch_repair_auto_approve",
            "source" => "Repository##{@job.repository_id}"
          }
        )
        @job.save!
        approved = true
      end
    end

    return skipped(reason) unless approved

    audit!
    Syrus::Host::LandingQueueProcessor.try_land!(@job)

    Result.new(approved: true, reason: nil)
  end

  private

  def skipped(reason)
    Result.new(approved: false, reason: reason)
  end

  def audit!
    run = @job.current_run
    return unless run

    JobLog.append!(run: run, chunk: "auto_approval: approved main branch repair via repository setting", kind: "system")
  end
end
