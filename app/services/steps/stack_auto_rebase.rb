module Steps
  class StackAutoRebase < Base
    def call
      log("stack_auto_rebase: attempting deterministic stack rebase (workflow ##{workflow.id})")

      results = []
      pending = []

      stack_entries.each do |entry|
        stack_job = Job.find_by(id: entry.fetch("job_id"))
        unless rebaseable_job?(stack_job)
          results << entry.merge("result" => { "succeeded" => false, "reason" => "not_rebaseable" })
          pending << entry
          break
        end

        result = ::AutoRebase.new(stack_job, base_branch: entry["base_branch"]).call
        results << entry.merge("result" => result.to_h)

        if result.succeeded?
          log("stack_auto_rebase: job #{stack_job.id} clean - #{result.note || result.reason}")
          next
        end

        log("stack_auto_rebase: job #{stack_job.id} #{result.reason} - falling through to stack_agent_rebase")
        pending << entry
        break
      end

      processed_ids = results.map { |entry| entry["job_id"] }
      pending.concat(stack_entries.reject { |entry| processed_ids.include?(entry["job_id"]) })
      workflow.set_artifact!(StackRebasePlan::RESULTS_ARTIFACT, results)
      workflow.set_artifact!(StackRebasePlan::AGENT_PENDING_ARTIFACT, pending)

      cancel_agent_rebase! if pending.empty?
    end

    private

    def stack_entries
      Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT))
    end

    def rebaseable_job?(stack_job)
      stack_job&.open? && stack_job.branch_name.present? && (stack_job.pr_number.present? || stack_job.external_pr_number.present?)
    end

    def cancel_agent_rebase!
      next_step = step.next_step
      return unless next_step&.kind == "stack_agent_rebase"
      return unless next_step.may_cancel?

      log("[#{step.kind}] cancelling downstream step ##{next_step.id} (#{next_step.kind}): stack auto-rebase already succeeded")
      Step.suppress_cancel_cascade do
        next_step.cancel!
        next_step.save!
      end
    end
  end
end
