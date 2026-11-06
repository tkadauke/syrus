require "fileutils"

class Coworkers::ReviewMemoryLifecycle
  PersistenceError = Class.new(StandardError)
  APPROVED_MEMORY_PATH = %r{\Amemory/[a-z0-9][a-z0-9_.-]*\.md\z}.freeze

  class << self
    def prepare!(coworker:, run:, evidence:, criteria:)
      existing = Coworkers::ReviewContext.find_by(run: run)
      return existing if existing

      selected = eligible_memories(coworker, run)
      identity = [ "Name: #{coworker.name}", "Handle: @#{coworker.handle}", "Role: #{coworker.role_summary}" ].join("\n")
      memory_text = selected.map { |entry| "[memory #{entry.id} revision #{entry.updated_at.iso8601}]\n#{entry.content}" }.join("\n\n")
      exact = { "identity" => identity, "repository_criteria" => Array(criteria).join("\n\n"), "repository_memories" => memory_text }
      path = checkout_path(run)
      clone_home!(coworker, run, path)
      manifest = exact.transform_values { |text| { "bytes" => text.bytesize, "sha256" => Digest::SHA256.hexdigest(text) } }
      manifest["memories"] = selected.map { |entry| { "id" => entry.id, "revision" => entry.updated_at.iso8601, "sha256" => Digest::SHA256.hexdigest(entry.content) } }
      Coworkers::ReviewContext.create!(run:, review_evidence: evidence, coworker:, manifest:, exact_context: exact, workspace_path: path.to_s)
    end

    def prompt_section(context)
      exact = context.exact_context
      [ "# Protected coworker reviewer context", exact.fetch("identity"),
        exact.fetch("repository_memories").presence && "## Selected repository memories\n#{exact.fetch('repository_memories')}" ].compact.join("\n\n")
    end

    def update!(coworker:, run:, path:, content:)
      context = context_for!(coworker, run)
      relative = path.to_s.downcase
      raise ArgumentError, "path must match memory/<name>.md" unless relative.match?(APPROVED_MEMORY_PATH)
      raise ArgumentError, "memory content is too large" if content.to_s.bytesize > 32.kilobytes

      destination = safe_destination(context, relative)
      FileUtils.mkdir_p(destination.dirname)
      File.write(destination, content.to_s)
      relative
    end

    def persist!(coworker:, run:, key_learning:, verdict:)
      context = context_for!(coworker, run)
      return context if context.persistence_state == "persisted"

      journal = safe_destination(context, "reviews/journal/run-#{run.id}.md")
      FileUtils.mkdir_p(journal.dirname)
      File.write(journal, <<~TEXT)
        # Repository review
        Job: #{run.job_id}
        Workflow: #{run.workflow_id}
        Run: #{run.id}
        Reviewed SHA: #{context.review_evidence.reviewed_head_sha}
        Verdict: #{verdict}
        Key learning: #{key_learning}
        Evidence: #{context.review_evidence_id}
      TEXT
      persist_checkout!(coworker, run, context)
    rescue StandardError => error
      context&.update!(persistence_state: "failed", persistence_error_code: "coworker_memory_persistence_failed",
                       persistence_error_details: { "class" => error.class.name, "message" => error.message.to_s.truncate(500) })
      raise PersistenceError, error.message
    end

    private

    def eligible_memories(coworker, run)
      return [] unless defined?(AgentMemory::Entry)

      AgentMemory::Entry.active.repository_scope(run.job.repository_id)
        .where(user_id: coworker.owner_user_id, published: true).order(:id).to_a
    end

    def checkout_path(run)
      WorkflowWorkspace.new(run.workflow).path.dirname.join("coworker-review-workspaces", run.id.to_s)
    end

    def clone_home!(coworker, run, path)
      FileUtils.rm_rf(path)
      FileUtils.mkdir_p(path.dirname)
      repository = coworker.workspace_repository or raise ArgumentError, "coworker workspace repository is unavailable"
      GitRunner.new.run("clone", "--branch", "coworkers/#{coworker.handle}", "--single-branch",
                        repository.authenticated_url(user: run.job.owner_user || run.job.user), path.to_s,
                        env: { "GIT_TERMINAL_PROMPT" => "0" })
    end

    def context_for!(coworker, run)
      Coworkers::ReviewContext.find_by!(run:, coworker:)
    end

    def safe_destination(context, relative)
      root = Pathname(context.workspace_path).realpath
      destination = root.join(relative).cleanpath
      raise ArgumentError, "memory path escapes the reviewer workspace" unless destination.to_s.start_with?("#{root}/")
      cursor = root
      Pathname(relative).each_filename do |component|
        cursor = cursor.join(component)
        raise ArgumentError, "symlinks are not allowed in reviewer memory paths" if cursor.symlink?
      end
      destination
    end

    def persist_checkout!(coworker, run, context)
      path = context.workspace_path
      git = GitRunner.new
      if git.run("status", "--porcelain", chdir: path).present?
        git.configure_author(Coworkers::GitIdentity.new(name: coworker.name, handle: coworker.handle), chdir: path)
        git.run("add", "--all", chdir: path)
        git.run("commit", "-m", "Record repository review run #{run.id}", chdir: path)
      end
      branch = "coworkers/#{coworker.handle}"
      repository = coworker.workspace_repository
      url = repository.authenticated_url(user: run.job.owner_user || run.job.user)
      3.times do |attempt|
        begin
          git.run("push", url, "HEAD:refs/heads/#{branch}", chdir: path, env: { "GIT_TERMINAL_PROMPT" => "0" })
          sha = git.run("rev-parse", "HEAD", chdir: path).strip
          return context.update!(persistence_state: "persisted", persisted_commit_sha: sha, persisted_at: Time.current,
                                 persistence_error_code: nil, persistence_error_details: {})
        rescue GitRunner::GitError => error
          raise unless error.message.match?(/non-fast-forward|fetch first|rejected.*behind/i) && attempt < 2
          git.run("pull", "--rebase", url, branch, chdir: path, env: { "GIT_TERMINAL_PROMPT" => "0" })
        end
      end
    end
  end
end
