module Steps
  class PublishSourceSnapshot < Base
    def call
      workspace.setup
      source_sha = head_sha
      source_ref = "refs/syrus/source-snapshots/runs/#{run.id}"

      authenticated_git("git_base_refresh_source_snapshot_push") do |url|
        GitRunner.new.run(
          "push", url, "#{source_sha}:#{source_ref}",
          chdir: workspace.path.to_s,
          env: { "GIT_TERMINAL_PROMPT" => "0" }
        )
      end

      snapshot = WorkflowSourceSnapshots.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: source_sha,
        source_ref: source_ref,
        tree_sha: GitRunner.new.run("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).strip
      )
      workflow.set_artifact!("base_refresh_source_snapshot_id", snapshot.id)
      log("[publish_source_snapshot] published #{source_ref} at #{source_sha.first(12)}")
    rescue GitRunner::GitError => e
      raise WorkflowSourceSnapshots::InfrastructureStateError,
            "refreshed source snapshot publication failed: #{e.message}"
    end
  end
end
