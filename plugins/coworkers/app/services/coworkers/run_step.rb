module Coworkers
  class RunStep < ::Steps::Base
    class PersistenceFailed < StepFailed; end

    def call
      workspace.setup
      run.update!(prompt: prompt) if run.prompt.blank?
      log("invoking coworker for background run (#{workflow.slug})")
      result = run_agent(prompt: run.prompt, workload_policy: Execution::ChatWorkloadPolicy.for_current_setting)
      run.update!(agent_summary: result.final_text.to_s.strip.presence)
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
      return if outcome == :merged

      fail_persistence!(
        "Workspace persistence #{outcome}. The run output remains recoverable from the workspace and its background-run ref; " \
        "resolve the workspace conflict from the main chat before retrying."
      )
    rescue GitRunner::GitError => error
      fail_persistence!(
        "Workspace persistence failed while pushing the background run: #{error.message}. " \
        "The run output remains recoverable in its workflow workspace; restore repository access, then retry the run."
      )
    end

    def verify_claimed_paths!
      claimed = Coworkers::ClaimedWorkspacePaths.from(run.agent_summary)
      return if claimed.empty?

      persisted = GitRunner.new.run("ls-tree", "-r", "--name-only", "HEAD", chdir: workspace.path.to_s).lines.map(&:strip).to_set
      missing = claimed - persisted.to_a
      return if missing.empty?

      subject = missing.one? ? "that path was" : "those paths were"
      fail_persistence!(
        "Workspace persistence warning: the run claimed to write #{missing.join(', ')}, but " \
        "#{subject} not present in the persisted background-run tree. " \
        "The run was marked failed instead of reporting a false success."
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

        Work in the checked-out coworker workspace. Interactive-only tools are unavailable. Any action requiring owner confirmation must be queued for approval instead of waiting for a live response.
      TEXT
    end
  end
end
