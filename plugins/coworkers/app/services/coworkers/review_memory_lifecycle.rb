require "fileutils"
require "shellwords"
require "tempfile"
require "uri"

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
      criteria_text = Array(criteria).map { |criterion| "- #{criterion}" }.join("\n")
      protected_prompt = [ "# Protected coworker reviewer context", identity,
        "## Review instructions\n#{Prompts::CoworkerReview.protected_instructions}",
        criteria_text.present? && "## Applicable repository criteria\n#{criteria_text}",
        memory_text.present? && "## Selected repository memories\n#{memory_text}" ].compact.join("\n\n")
      exact = { "protected_prompt" => protected_prompt }
      path = checkout_path(run)
      clone_home!(coworker, run, path)
      manifest = { "protected_prompt" => { "bytes" => protected_prompt.bytesize,
        "sha256" => Digest::SHA256.hexdigest(protected_prompt) } }
      manifest["memories"] = selected.map { |entry| { "id" => entry.id, "revision" => entry.updated_at.iso8601, "sha256" => Digest::SHA256.hexdigest(entry.content) } }
      Coworkers::ReviewContext.create!(run:, review_evidence: evidence, coworker:, manifest:, exact_context: exact, workspace_path: path.to_s)
    end

    def prompt_section(context)
      context.exact_context.fetch("protected_prompt")
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
      context = nil
      Coworkers::OperationLock.with(coworker, wait: 30) do
        context = context_for!(coworker, run)
        return context if context.persistence_state == "persisted"

        journal = safe_destination(context, "reviews/journal/evidence-#{context.review_evidence_id}.md")
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
      end
    rescue StandardError => error
      context&.update!(persistence_state: "failed", persistence_error_code: "coworker_memory_persistence_failed",
                       persistence_error_details: { "class" => error.class.name, "message" => "coworker memory persistence failed" })
      raise PersistenceError, "coworker memory persistence failed"
    end

    private

    def eligible_memories(coworker, run)
      return [] unless defined?(AgentMemory::Entry)

      ids = Array(run.step.details.to_h["review_memory_ids"]).filter_map { |value| Integer(value, exception: false) }.uniq
      return [] if ids.empty?

      AgentMemory::Entry.active.repository_scope(run.job.repository_id)
        .where(id: ids, user_id: coworker.owner_user_id, published: true).order(:id).to_a
    end

    def checkout_path(run)
      Coworkers::ReviewWorkspace.path_for(run)
    end

    def clone_home!(coworker, run, path)
      FileUtils.rm_rf(path)
      FileUtils.mkdir_p(path.dirname)
      repository = coworker.workspace_repository or raise ArgumentError, "coworker workspace repository is unavailable"
      with_git_auth(repository, run, operation_type: "coworker_review_clone") do |url, env|
        GitRunner.new.run("clone", "--branch", "coworkers/#{coworker.handle}", "--single-branch", url, path.to_s, env:)
      end
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
      3.times do |attempt|
        begin
          with_git_auth(repository, run, operation_type: "coworker_review_reconcile") do |url, env|
            git.run("fetch", url, "+refs/heads/#{branch}:refs/remotes/origin/#{branch}", chdir: path, env:)
          end
          git.run("rebase", "origin/#{branch}", chdir: path)
          expected_sha = git.run("rev-parse", "origin/#{branch}", chdir: path).strip
          lease = "--force-with-lease=refs/heads/#{branch}:#{expected_sha}"
          with_git_auth(repository, run, operation_type: "coworker_review_push") do |url, env|
            git.run("push", lease, url, "HEAD:refs/heads/#{branch}", chdir: path, env:)
          end
          sha = git.run("rev-parse", "HEAD", chdir: path).strip
          return context.update!(persistence_state: "persisted", persisted_commit_sha: sha, persisted_at: Time.current,
                                 persistence_error_code: nil, persistence_error_details: {})
        rescue GitRunner::GitError
          git.run("rebase", "--abort", chdir: path) rescue nil
          raise PersistenceError, "the coworker home branch contains conflicting memory changes" if attempt == 2
        end
      end
    end

    def with_git_auth(repository, run, operation_type:)
      user = run.job.owner_user || run.job.user
      git = GitRunner.new
      GithubAuthenticatedGit.run(repository:, user:, git:, operation_type:) do |authenticated_url|
        uri = URI.parse(authenticated_url)
        username, password = uri.userinfo.to_s.split(":", 2)
        uri.user = nil
        uri.password = nil
        Tempfile.create([ "coworker-review-askpass-", ".sh" ]) do |file|
          file.write("#!/bin/sh\ncase \"$1\" in\n  *Username*) printf '%s\\n' #{Shellwords.escape(username.to_s)} ;;\n  *) printf '%s\\n' #{Shellwords.escape(password.to_s)} ;;\nesac\n")
          file.flush
          File.chmod(0o700, file.path)
          yield uri.to_s, { "GIT_ASKPASS" => file.path, "GIT_TERMINAL_PROMPT" => "0" }
        end
      end
    end
  end
end
