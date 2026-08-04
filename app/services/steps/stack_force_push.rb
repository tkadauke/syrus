module Steps
  class StackForcePush < Base
    def call
      workspace.setup

      pushes = Array(workflow.artifact(StackRebasePlan::AGENT_PUSHES_ARTIFACT))
      if pushes.empty?
        log("stack_force_push: skipped branch pushes - deterministic stack rebase already pushed clean branches")
      else
        push_agent_rebased_branches(pushes)
      end

      update_pull_request_bases
      refresh_stack_footers
    end

    private

    def stack_entries
      Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT))
    end

    def push_agent_rebased_branches(pushes)
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })

      pushes.each do |entry|
        branch = entry.fetch("branch_name")
        log("stack_force_push: pushing rebased #{branch} (#{workflow.slug})")
        GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_stack_force_push", log: method(:log)) do |push_url|
          git.run("push", force_with_lease_arg(entry), push_url, "#{branch}:refs/heads/#{branch}", chdir: workspace.path.to_s)
        end
      rescue GitRunner::GitError => e
        raise unless push_rejected?(e)

        message = "stack_force_push: lease rejected for #{branch}; remote branch moved after Syrus fetched it. Refusing to overwrite newer remote work."
        log(message)
        raise StepFailed, message
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
        base = entry["base_branch"].presence || repository.default_branch
        next if pr_number.blank?

        client.update_pull_request_base(repository.slug, pr_number, base: base)
      rescue StandardError => e
        log("stack_force_push: failed to update PR ##{pr_number} base to #{base}: #{e.class}: #{e.message}")
      end
    end

    def refresh_stack_footers
      stack_entries.each do |entry|
        stack_job = Job.find_by(id: entry["job_id"])
        next unless stack_job

        PrStackFooter.refresh!(stack_job)
      rescue StandardError => e
        log("stack_force_push: failed to refresh stack footer for #{::App::Presentation.job_slug(entry["job_id"])}: #{e.class}: #{e.message}")
      end
    end
  end
end
