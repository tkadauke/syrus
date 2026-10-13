module Steps
  class SpeculativeLandingBuild < Base
    def call
      source_path = Pathname.new(required_artifact!("prefetch_source_workspace_path"))
      source_workflow = source_workflow!
      source_head = required_artifact!("prefetch_source_head_sha")
      candidate_head = workflow.artifact("prefetch_candidate_head_sha").presence

      raise StepFailed, "speculative_landing: source workspace is missing" unless source_path.exist?

      workspace.setup
      git = GitRunner.new(log_sink: ->(line) { log(line, kind: "system") })
      verify_source!(git, source_path, source_workflow, source_head)
      verify_candidate_head!(git, candidate_head) if candidate_head.present?

      git.run("fetch", "--no-tags", source_path.to_s, "HEAD", chdir: workspace.path.to_s)
      fetched = git.run("rev-parse", "FETCH_HEAD", chdir: workspace.path.to_s).strip
      unless fetched == source_head
        raise StepFailed, "speculative_landing: predicted base moved from #{source_head.first(7)} to #{fetched.first(7)}"
      end

      log("speculative_landing: rebasing #{job.slug} onto predicted base #{source_head.first(7)}", kind: "system")
      git.run("rebase", "FETCH_HEAD", chdir: workspace.path.to_s)

      head_sha = git.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
      tree_sha = git.run("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).strip
      workflow.set_artifact!("speculative_landing_head_sha", head_sha)
      workflow.set_artifact!("speculative_landing_tree_sha", tree_sha)
      log("speculative_landing: built #{head_sha.first(7)} on predicted base #{source_head.first(7)}", kind: "system")
    rescue GitRunner::GitError => e
      raise StepFailed, "speculative_landing: #{e.message}"
    end

    private

    def required_artifact!(key)
      value = workflow.artifact(key).presence
      raise StepFailed, "speculative_landing: missing #{key}" if value.blank?

      value
    end

    def source_workflow!
      workflow_id = required_artifact!("prefetch_source_workflow_id").to_i
      Workflow.find_by(id: workflow_id) ||
        raise(StepFailed, "speculative_landing: source workflow #{workflow_id} is missing")
    end

    def verify_source!(git, source_path, source_workflow, source_head)
      actual = git.run("rev-parse", "HEAD", chdir: source_path.to_s, workflow: source_workflow).strip
      return if actual == source_head

      raise StepFailed, "speculative_landing: source workflow moved from #{source_head.first(7)} to #{actual.first(7)}"
    end

    def verify_candidate_head!(git, candidate_head)
      actual = git.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
      return if actual == candidate_head

      raise StepFailed, "speculative_landing: candidate head moved from #{candidate_head.first(7)} to #{actual.first(7)}"
    end
  end
end
