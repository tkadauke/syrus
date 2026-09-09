module Steps
  class StackAutoRebase < Base
    def call
      log("stack_auto_rebase: attempting deterministic stack rebase (#{workflow.slug})")

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

        finalize_already_landed!(stack_job, entry, result) if result.reason == ::AutoRebase::ALREADY_LANDED_REASON

        if result.succeeded?
          log("stack_auto_rebase: #{stack_job.slug} clean - #{result.note || result.reason}")
          next
        end

        log("stack_auto_rebase: #{stack_job.slug} #{result.reason} - falling through to stack_agent_rebase")
        pending << entry
        break
      end

      processed_ids = results.map { |entry| entry["job_id"] }
      pending.concat(stack_entries.reject { |entry| processed_ids.include?(entry["job_id"]) })
      workflow.set_artifact!(StackRebasePlan::RESULTS_ARTIFACT, results)
      workflow.set_artifact!(StackRebasePlan::AGENT_PENDING_ARTIFACT, pending)

      skip_agent_rebase! if pending.empty?
    end

    private

    def stack_entries
      Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT))
    end

    def rebaseable_job?(stack_job)
      stack_job&.open? && stack_job.branch_name.present? && (stack_job.pr_number.present? || stack_job.external_pr_number.present?)
    end

    def finalize_already_landed!(stack_job, entry, result)
      base_branch = entry["base_branch"].presence || stack_job.effective_base_branch

      if stack_job.may_close?
        stack_job.close_with_reason!("pr_merged")
        log("stack_auto_rebase: #{stack_job.slug} closed as pr_merged - #{result.note}")
      else
        log("stack_auto_rebase: #{stack_job.slug} is #{stack_job.state} and was left as-is - #{result.note}")
      end

      close_landed_pull_request!(stack_job, base_branch)
    rescue StandardError => e
      log("stack_auto_rebase: could not finalize #{stack_job.slug} as landed: #{e.class}: #{e.message}")
    end

    def close_landed_pull_request!(stack_job, base_branch)
      return if stack_job.pr_number.blank?

      client = GithubClient.for(repository: stack_job.repository, user: stack_job.user)
      client.add_issue_comment(
        stack_job.repository.slug, stack_job.pr_number,
        "Closing: every commit on `#{stack_job.branch_name}` is already on `#{base_branch}`, " \
        "so this PR has nothing left to merge. Syrus recorded #{stack_job.slug} as landed."
      )
      client.close_pull_request(stack_job.repository.slug, stack_job.pr_number)
    end

    def skip_agent_rebase!
      next_step = step.next_step
      return unless next_step&.kind == "stack_agent_rebase"
      return unless next_step.may_skip?

      reason = "stack auto-rebase already succeeded"
      log("[#{step.kind}] skipping downstream step ##{next_step.id} (#{next_step.kind}): #{reason}")
      next_step.skip_with_reason!(reason)
    end
  end
end
