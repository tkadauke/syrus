module Steps
  class StackForcePush < Base
    def call
      workspace.setup

      pushes = Array(workflow.artifact(StackRebasePlan::AGENT_PUSHES_ARTIFACT))
      if pushes.empty?
        log("stack_force_push: no branch rewrite needed; live PR base and topology still require publication verification")
      else
        push_agent_rebased_branches(pushes)
      end

      update_pull_request_bases
      refresh_stack_footers
      verify_publication!(pushes)
    end

    private

    def stack_entries
      Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT))
    end

    def push_agent_rebased_branches(pushes)
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })

      pushes.each do |entry|
        branch = entry.fetch("branch_name")
        post_sha = entry.fetch("post_sha")
        log("stack_force_push: pushing rebased #{branch} (#{workflow.slug})")
        GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_stack_force_push", log: method(:log)) do |push_url|
          git.run("push", force_with_lease_arg(entry), push_url, "#{post_sha}:refs/heads/#{branch}", chdir: workspace.path.to_s)
        end
      rescue GithubPushProtection::Rejected => e
        # Multi-branch stack push: no in-place repair; record evidence for the owning Job and stop.
        handle_push_protection_rejection!(e)
      rescue GitRunner::GitError => e
        unless push_rejected?(e)
          record_publication_failure!(entry, "provider_failure", e)
          raise StepFailed.new("stack_force_push: provider failed while pushing #{branch}: #{e.message}", evidence: publication_failure_artifact)
        end

        message = "stack_force_push: lease rejected for #{branch}; remote branch moved after Syrus fetched it. Refusing to overwrite newer remote work."
        record_publication_failure!(entry, "lease_rejected", e)
        log(message)
        raise StepFailed.new(message, evidence: publication_failure_artifact)
      end
    end

    def force_with_lease_arg(entry)
      branch = entry.fetch("branch_name")
      expected_sha = entry["pre_sha"].presence
      return "--force-with-lease=refs/heads/#{branch}:#{expected_sha}" if expected_sha

      "--force-with-lease"
    end

    def update_pull_request_bases
      client = GithubClient.for(repository: repository, user: job.user)
      stack_entries.each do |entry|
        pr_number = entry["pr_number"]
        stack_job = Job.find_by(id: entry["job_id"])
        next if stack_job&.closed?
        base = stack_job&.effective_base_branch.presence || entry["base_branch"].presence || repository.default_branch

        resolution = JobStackResolver.new(stack_job, workflow: workflow).resolve!
        unless resolution.ready? && resolution.parent&.id == entry["parent_job_id"]
          evidence = {
            "expected_parent_job_id" => entry["parent_job_id"],
            "resolved_parent_job_id" => resolution.parent&.id,
            "resolution_reason" => resolution.reason
          }
          error = StackPublicationVerifier::Mismatch.new("derived stack topology no longer matches the publication plan", evidence: evidence)
          record_publication_failure!(entry, "postcondition_mismatch", error, evidence)
          raise StepFailed.new("stack_force_push: derived stack topology no longer matches the publication plan", evidence: publication_failure_artifact)
        end

        base = stack_job.reload.effective_base_branch.presence || entry["base_branch"].presence || repository.default_branch
        next if pr_number.blank?

        client.update_pull_request_base(repository.slug, pr_number, base: base)
      rescue StepFailed
        raise
      rescue StandardError => e
        category = provider_auth_failure?(e) ? "provider_auth_failure" : "provider_failure"
        record_publication_failure!(entry, category, e, "expected_base" => base, "pr_number" => pr_number)
        message = "stack_force_push: #{category.tr('_', ' ')} while updating PR ##{pr_number} base to #{base}: #{e.class}: #{e.message}"
        log(message)
        raise StepFailed.new(message, evidence: publication_failure_artifact)
      end
    end

    def refresh_stack_footers
      stack_entries.each do |entry|
        stack_job = Job.find_by(id: entry["job_id"])
        next unless stack_job

        PrStackFooter.refresh!(stack_job)
      rescue StandardError => e
        record_publication_failure!(entry, "topology_refresh_failure", e)
        message = "stack_force_push: failed to refresh stack footer for #{::App::Presentation.job_slug(entry["job_id"])}: #{e.class}: #{e.message}"
        log(message)
        raise StepFailed.new(message, evidence: publication_failure_artifact)
      end
    end

    def verify_publication!(pushes)
      StackPublicationVerifier.new(workflow: workflow, repository: repository, user: job.user)
        .verify!(
          entries: stack_entries,
          expected_heads: expected_heads(pushes),
          publication_mode: pushes.empty? ? "already_correct" : "rewritten"
        )
      log("stack_force_push: publication verified against live branch, PR, stack, and landing state")
    rescue StackPublicationVerifier::Mismatch => e
      entry = stack_entries.find { |candidate| candidate["job_id"] == e.evidence["job_id"] } || {}
      record_publication_failure!(entry, "postcondition_mismatch", e, e.evidence)
      message = "stack_force_push: publication postcondition mismatch: #{e.message}"
      log(message)
      raise StepFailed.new(message, evidence: publication_failure_artifact)
    rescue StepFailed
      raise
    rescue StandardError => e
      category = provider_auth_failure?(e) ? "provider_auth_failure" : "topology_refresh_failure"
      record_publication_failure!({}, category, e)
      message = "stack_force_push: #{category.tr('_', ' ')} while verifying publication: #{e.class}: #{e.message}"
      log(message)
      raise StepFailed.new(message, evidence: publication_failure_artifact)
    end

    def expected_heads(pushes)
      agent_heads = pushes.filter_map do |entry|
        [ entry["job_id"], entry["post_sha"] ] if entry["job_id"].present?
      end.to_h.compact
      deterministic_heads = Array(workflow.artifact(StackRebasePlan::RESULTS_ARTIFACT)).to_h do |entry|
        [ entry["job_id"], entry.dig("result", "post_sha") ]
      end
      deterministic_heads.merge(agent_heads)
    end

    def record_publication_failure!(entry, category, error, extra = {})
      expected_head = expected_heads(Array(workflow.artifact(StackRebasePlan::AGENT_PUSHES_ARTIFACT)))[entry["job_id"]]
      remote_head = begin
        GithubClient.for(repository: repository, user: job.user).branch_head_sha(repository.slug, entry["branch_name"])
      rescue StandardError
        nil
      end
      artifact = {
        "category" => category,
        "job_id" => entry["job_id"],
        "branch" => entry["branch_name"],
        "remote_sha" => remote_head,
        "local_sha" => expected_head,
        "detected_at" => Time.current.iso8601,
        "message" => error.message
      }.merge(extra)
      workflow.set_artifact!("stack_publication_failure", artifact)
      if expected_head.present? && expected_head != remote_head
        workflow.set_artifact!("branch_divergence", artifact.slice("branch", "remote_sha", "local_sha", "detected_at", "message"))
      end
    end

    def publication_failure_artifact
      workflow.artifact("stack_publication_failure").to_h
    end

    def provider_auth_failure?(error)
      error.is_a?(Octokit::Unauthorized) || error.is_a?(Octokit::Forbidden)
    end
  end
end
