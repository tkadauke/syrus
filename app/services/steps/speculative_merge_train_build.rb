module Steps
  class SpeculativeMergeTrainBuild < Base
    def call
      @source_path = Pathname.new(required_artifact!("prefetch_source_workspace_path"))
      @source_head = required_artifact!("prefetch_source_head_sha")
      @members = member_jobs
      raise StepFailed, "speculative_merge_train: no members to build" if @members.empty?
      raise StepFailed, "speculative_merge_train: source workspace is missing" unless @source_path.exist?

      workspace.setup
      @chdir = workspace.path.to_s
      @git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_EDITOR" => "true" })
      @integration = "__syrus_speculative_merge_train_#{workflow.id}"

      verify_source!
      fetch_predicted_base!
      @git.run("checkout", "-B", @integration, "FETCH_HEAD", chdir: @chdir)
      log("speculative_merge_train: integration #{@integration} started at predicted base #{@source_head.first(9)}")

      @members.each { |member| integrate!(member) }

      @git.run("checkout", @integration, chdir: @chdir)
      head_sha = @git.run("rev-parse", "HEAD", chdir: @chdir).strip
      tree_sha = @git.run("rev-parse", "HEAD^{tree}", chdir: @chdir).strip
      workflow.set_artifact!("speculative_landing_head_sha", head_sha)
      workflow.set_artifact!("speculative_landing_tree_sha", tree_sha)
      workflow.set_artifact!("merge_train_base_sha", @source_head)
      log("speculative_merge_train: built #{head_sha.first(9)} from #{@members.size} member(s)")
    rescue GitRunner::GitError => e
      raise StepFailed, "speculative_merge_train: #{e.message}"
    end

    private

    def required_artifact!(key)
      value = workflow.artifact(key).presence
      raise StepFailed, "speculative_merge_train: missing #{key}" if value.blank?

      value
    end

    def member_jobs
      ids = Array(required_artifact!("prefetch_merge_train_member_job_ids")).map(&:to_i).reject(&:zero?)
      jobs = Job.where(id: ids).index_by(&:id)
      ids.filter_map { |id| jobs[id] }
    end

    def verify_source!
      actual = @git.run("rev-parse", "HEAD", chdir: @source_path.to_s).strip
      return if actual == @source_head

      raise StepFailed, "speculative_merge_train: source workflow moved from #{@source_head.first(7)} to #{actual.first(7)}"
    end

    def fetch_predicted_base!
      @git.run("fetch", "--no-tags", @source_path.to_s, "HEAD", chdir: @chdir)
      fetched = @git.run("rev-parse", "FETCH_HEAD", chdir: @chdir).strip
      return if fetched == @source_head

      raise StepFailed, "speculative_merge_train: predicted base moved from #{@source_head.first(7)} to #{fetched.first(7)}"
    end

    def integrate!(member)
      branch = member.branch_name.presence
      raise StepFailed, "speculative_merge_train: member #{member.slug} has no branch" if branch.blank?

      fetch_branch!(branch)
      temp = "__syrus_speculative_mt_member_#{member.id}"
      @git.run("checkout", "-B", temp, "FETCH_HEAD", chdir: @chdir)
      @git.run("rebase", @integration, chdir: @chdir)
      verify_rebased!(branch, temp)
      @git.run("checkout", @integration, chdir: @chdir)
      @git.run("merge", "--ff-only", temp, chdir: @chdir)
      @git.run("branch", "-D", temp, chdir: @chdir)
      log("speculative_merge_train: integrated #{member.slug} (#{branch})")
    rescue GitRunner::GitError => e
      abort_rebase!
      raise StepFailed, "speculative_merge_train: could not integrate #{member.slug} cleanly: #{e.message}"
    end

    def fetch_branch!(branch)
      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: @git, operation_type: "git_speculative_merge_train_fetch", log: method(:log)) do |url|
        @git.run("fetch", url, "refs/heads/#{branch}", chdir: @chdir)
      end
    end

    def verify_rebased!(branch, temp)
      @git.run("checkout", temp, chdir: @chdir)
      status = @git.run("status", "--porcelain", chdir: @chdir).to_s.strip
      raise StepFailed, "speculative_merge_train: integrating #{branch} left a dirty worktree" unless status.empty?

      @git.run("merge-base", "--is-ancestor", @integration, temp, chdir: @chdir)
    rescue GitRunner::GitError => e
      raise StepFailed, "speculative_merge_train: #{branch} was not cleanly rebased onto the predicted integration branch: #{e.message}"
    end

    def abort_rebase!
      @git.run("rebase", "--abort", chdir: @chdir)
    rescue GitRunner::GitError
      nil
    end
  end
end
