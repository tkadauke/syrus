module WorkflowSourceSnapshots
  class RefPublisher
    ARTIFACT_KEY = "source_snapshot_ref_publication_failure"
    MAX_ATTEMPTS = 3
    RETRY_DELAYS = [ 0.25, 1.0 ].freeze
    TRANSIENT_FAILURE = /(?:commit_refs_rules|internal server error|http 5\d\d|http 429|too many requests|timed? out|timeout|connection (?:lost|reset|refused)|could not resolve host|temporary failure|remote end hung up|service unavailable|bad gateway|gateway timeout|network is unreachable|early eof)/i

    def self.publish!(...) = new(...).publish!

    def initialize(run:, workspace:, source_sha:, remote_ref:, git: nil, log: nil, sleeper: Kernel, random: Random)
      @run = run
      @workspace = workspace
      @source_sha = source_sha
      @remote_ref = remote_ref
      @git = git || GitRunner.new
      @log = log
      @sleeper = sleeper
      @random = random
    end

    def publish!
      failures = []

      MAX_ATTEMPTS.times do |index|
        attempt = index + 1
        begin
          return remote_ref if matching_remote_ref?

          push_ref!
          return remote_ref
        rescue GitRunner::GitError => error
          return remote_ref if matching_remote_ref_after_failure?

          failures << failure_evidence(error, attempt)
          raise permanent_failure(error) unless transient?(error)
          break if attempt == MAX_ATTEMPTS

          delay = retry_delay(index)
          failures.last["retry_delay_seconds"] = delay
          log("[grader_fanout] transient source snapshot ref publication failure (attempt #{attempt}/#{MAX_ATTEMPTS}); retrying in #{delay}s")
          @sleeper.sleep(delay)
        end
      end

      record_exhaustion!(failures)
      first = failures.first
      raise InfrastructureStateError,
            "workflow source snapshot ref publish failed for #{source_sha} after #{failures.size} attempts: #{first.fetch('message')}"
    end

    private

    attr_reader :run, :workspace, :source_sha, :remote_ref, :git

    def matching_remote_ref?
      existing_sha = remote_ref_sha
      return false if existing_sha.blank?
      return true if existing_sha == source_sha

      raise InfrastructureStateError,
            "workflow source snapshot ref #{remote_ref} points at #{existing_sha}, expected immutable SHA #{source_sha}"
    end

    def matching_remote_ref_after_failure?
      matching_remote_ref?
    rescue GitRunner::GitError
      false
    end

    def push_ref!
      authenticated_git("git_workflow_source_snapshot_push") do |url|
        git.run("push", url, "#{source_sha}:#{remote_ref}", chdir: workspace.path.to_s, env: env)
      end
    end

    def remote_ref_sha
      output = authenticated_git("git_workflow_source_snapshot_ls_remote") do |url|
        git.run("ls-remote", url, remote_ref, chdir: workspace.path.to_s, env: env)
      end
      output.to_s.lines.first.to_s.split(/\s+/).first.presence
    end

    def authenticated_git(operation_type, &block)
      GithubAuthenticatedGit.run(
        repository: run.job.repository,
        user: run.user,
        git: git,
        operation_type: operation_type,
        log: ->(message, **kwargs) { log(message, **kwargs) },
        &block
      )
    end

    def transient?(error)
      !error.is_a?(GithubPushProtection::Rejected) && error.message.match?(TRANSIENT_FAILURE)
    end

    def permanent_failure(error)
      InfrastructureStateError.new("workflow source snapshot ref publish failed for #{source_sha}: #{error.message}")
    end

    def retry_delay(index)
      base = RETRY_DELAYS.fetch(index)
      (base + (@random.rand * base * 0.25)).round(3)
    end

    def failure_evidence(error, attempt)
      {
        "attempt" => attempt,
        "classification" => "transient_remote_failure",
        "error_class" => error.class.name,
        "message" => error.message,
        "observed_at" => Time.current.iso8601
      }
    end

    def record_exhaustion!(failures)
      run.workflow.set_artifact!(ARTIFACT_KEY, {
        "run_id" => run.id,
        "step_id" => run.step_id,
        "source_sha" => source_sha,
        "source_ref" => remote_ref,
        "attempts" => failures,
        "original_error" => failures.first,
        "exhausted_at" => Time.current.iso8601
      })
    end

    def env
      { "GIT_TERMINAL_PROMPT" => "0" }
    end

    def log(message, **kwargs)
      @log&.call(message, **kwargs)
    end
  end
end
