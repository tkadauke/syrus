module Coworkers
  class RunStep < Syrus::Host::StepBase
    class PersistenceFailed < StepFailed; end

    def call
      workspace.setup
      @base_sha = workspace_head
      run.update!(prompt: prompt) if run.prompt.blank?
      log("invoking coworker for background run (#{workflow.slug})")
      result = run_agent(prompt: run.prompt, workload_policy: Syrus::Host::AgentRuntime.chat_workload_policy)
      run.update!(agent_summary: result.final_text.to_s.strip.presence)
      @written_paths = claims_present? ? written_paths : Set.new
      persist_workspace!
    end

    private

    def persist_workspace!
      coworker = Coworkers::Coworker.find(job.origin_id)
      chat = coworker.coworker_chats.find_by!(role: "main").chat_session
      outcome = Coworkers::PostToChat.finalize_once!(
        chat:, workflow:, source_run: run, path: workspace.path
      )
      verify_claimed_paths! if outcome == :merged
      return if %i[merged pending_resolution].include?(outcome)

      fail_persistence!(
        "Workspace persistence #{outcome}. The run output remains recoverable from the workspace and its background-run ref; " \
        "resolve the workspace conflict from the main chat before retrying."
      )
    rescue Syrus::Host::GitRunner::GitError => error
      fail_persistence!(
        "Workspace persistence failed while pushing the background run: #{error.message}. " \
        "The run output remains recoverable in its workflow workspace; restore repository access, then retry the run."
      )
    end

    def claims_present?
      summary = run.agent_summary
      Coworkers::ClaimedWorkspacePaths.from(summary).any? || Coworkers::ClaimedWorkspacePaths.unsupported_from(summary).any?
    end

    def workspace_head
      Syrus::Host::GitRunner.new.run("rev-parse", "--verify", "-q", "HEAD", chdir: workspace.path.to_s).strip.presence
    rescue Syrus::Host::GitRunner::GitError
      nil
    end

    # Exact files this run created or modified (not deletions, not files that
    # merely exist), relative to the commit the workspace started from.
    def written_paths
      git = Syrus::Host::GitRunner.new
      dir = workspace.path.to_s
      tracked = @base_sha ? git.run("diff", "--name-only", "--no-renames", "--diff-filter=ACMT", @base_sha, chdir: dir).lines : []
      untracked = git.run("ls-files", "--others", "--exclude-standard", chdir: dir).lines
      (tracked + untracked).map(&:strip).reject(&:empty?).select { |path| claimable_path?(path) }.to_set
    rescue Syrus::Host::GitRunner::GitError
      Set.new # unverifiable: fail closed, every claim is reported unsupported
    end

    def claimable_path?(path)
      path.start_with?("memory/") || Coworkers::ClaimedWorkspacePaths::CORE_FILES.include?(path)
    end

    def verify_claimed_paths!
      claimed = Coworkers::ClaimedWorkspacePaths.from(run.agent_summary)
      vague = Coworkers::ClaimedWorkspacePaths.unsupported_from(run.agent_summary)
      return if claimed.empty? && vague.empty?

      written = @written_paths || Set.new
      # An extensionless claim naming a directory of written files is vague; a
      # claim naming a written file is exact whatever its name looks like.
      directories = claimed.select { |path| written.none? { |w| w == path } && written.any? { |w| w.start_with?("#{path}/") } }
      vague |= directories
      missing = claimed - written.to_a - directories
      return if missing.empty? && vague.empty?

      fail_unsupported_claims!(missing, vague, written) if vague.any?

      subject = missing.one? ? "that path was" : "those paths were"
      fail_persistence!(
        "Workspace persistence warning: the run claimed to write #{missing.join(', ')}, but " \
        "#{subject} not created or edited by this run. " \
        "Paths written by this run: #{written.to_a.sort.first(50).join(', ').presence || 'none'}. " \
        "The run was marked failed instead of reporting a false success."
      )
    end

    def fail_unsupported_claims!(missing, vague, written)
      parts = [ "directory-level or wildcard claims (#{vague.join(', ')}) cannot be verified as exact file writes" ]
      parts << "claimed files not written by this run: #{missing.join(', ')}" if missing.any?
      fail_persistence!(
        "Workspace persistence warning: unsupported persistence claim: #{parts.join('; ')}. " \
        "Paths written by this run: #{written.to_a.sort.first(50).join(', ').presence || 'none'}. " \
        "The run was marked failed instead of reporting a false success. Report exact file paths only."
      )
    end

    def fail_persistence!(message)
      workflow.set_artifact!(Coworkers::PostToChat::MERGE_ARTIFACT, "failed")
      run.update!(agent_summary: message)
      raise PersistenceFailed, message
    end

    def prompt
      <<~TEXT.strip
        You are running an unattended background task as a persistent coworker.

        #{job.issue_body.presence || job.issue_title}

        Work in the checked-out coworker workspace. When you report saving anything to memory, name only the exact file paths (for example `memory/diary/2026-11-23.md`) that a successful workspace write tool call created or edited. Never report directories, wildcards, or paths you did not write, and never claim a save after a workspace tool returned an error. Interactive-only tools are unavailable. Any action requiring owner confirmation must be queued for approval instead of waiting for a live response.
      TEXT
    end
  end
end
