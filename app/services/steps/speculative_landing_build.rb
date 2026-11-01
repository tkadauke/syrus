module Steps
  class SpeculativeLandingBuild < Base
    def call
      source_head = required_artifact!("prefetch_source_head_sha")
      source_tree = required_artifact!("prefetch_source_tree_sha")
      snapshot_id = required_artifact!("prefetch_source_snapshot_id")
      candidate_head = workflow.artifact("prefetch_candidate_head_sha").presence

      workspace.setup
      git = GitRunner.new(log_sink: ->(line) { log(line, kind: "system") })
      verify_candidate_head!(git, candidate_head) if candidate_head.present?

      LandingValidationPrefetchSource.with_bundle(workflow, snapshot_id) do |snapshot, bundle_path|
        verify_snapshot!(snapshot, source_head, source_tree)
        git.run("fetch", "--no-tags", bundle_path, "HEAD", chdir: workspace.path.to_s)
      end
      verify_fetched_source!(git, source_head, source_tree)

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

    def verify_snapshot!(snapshot, source_head, source_tree)
      return if snapshot.source_sha == source_head && snapshot.tree_sha == source_tree

      raise StepFailed, "speculative_landing: source snapshot does not match the recorded predicted base"
    end

    def verify_fetched_source!(git, source_head, source_tree)
      fetched = git.run("rev-parse", "FETCH_HEAD", chdir: workspace.path.to_s).strip
      fetched_tree = git.run("rev-parse", "FETCH_HEAD^{tree}", chdir: workspace.path.to_s).strip
      return if fetched == source_head && fetched_tree == source_tree

      raise StepFailed, "speculative_landing: predicted base snapshot mismatch"
    end

    def verify_candidate_head!(git, candidate_head)
      actual = git.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
      return if actual == candidate_head

      raise StepFailed, "speculative_landing: candidate head moved from #{candidate_head.first(7)} to #{actual.first(7)}"
    end
  end
end
