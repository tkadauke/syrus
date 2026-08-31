module Steps
  # Non-agentic step that runs after the grader retry loop, alongside
  # coverage_analyze. Language plugins register :dependency_audit_command
  # providers (Ruby's `bundle-audit check`, JavaScript's `npm/yarn/pnpm
  # audit --json`, Python's `pip-audit`, Go's `govulncheck ./...`); this
  # step only runs a provider's command when the PR diff actually touched
  # one of that provider's declared lockfiles — reusing the diff-vs-default
  # computation grader_fanout/coverage_analyze already use rather than
  # re-implementing lockfile detection, and scoped to the same lockfile
  # ownership :prepare_detector's language plugins already encode.
  #
  # A non-zero exit status from an audit command is not a step failure —
  # it is how these tools report that vulnerabilities were found. Findings
  # are surfaced as a workflow artifact (and, when non-empty, a PR comment
  # body for Steps::PrOpen / Steps::DependencyAuditPrComment to post) —
  # never a hard grader failure. A clean scan across every scanned
  # ecosystem leaves no pr_comment_body, so nothing gets posted: silent by
  # design.
  class DependencyAudit < Base
    PER_COMMAND_TIMEOUT = 5.minutes.to_i
    OUTPUT_TAIL_BYTES = 8.kilobytes

    def call
      workspace.setup
      files = changed_files

      if files.empty?
        log("[dependency_audit] no changed files against #{default_branch_ref} — skipping")
        return
      end

      providers = matching_providers(files)
      if providers.empty?
        log("[dependency_audit] no changed lockfile matches a registered dependency_audit_command provider — skipping")
        return
      end

      results = providers.filter_map { |provider| run_provider(provider) }
      if results.empty?
        log("[dependency_audit] matched provider(s) declined to return a command — skipping")
        return
      end

      store_artifact!(results)
    end

    private

    def changed_files
      GitRunner.new.run("diff", "--name-only", "#{default_branch_ref}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
    rescue GitRunner::GitError => e
      log("[dependency_audit] warning: could not determine changed files: #{e.message}")
      []
    end

    def matching_providers(files)
      basenames = files.map { |f| File.basename(f) }
      Syrus::PluginRegistry.providers_for(:dependency_audit_command).select do |provider|
        Array(provider.lockfiles).any? { |lockfile| basenames.include?(lockfile) }
      end
    end

    def run_provider(provider)
      cmd = provider.audit_command(workspace_path: workspace.path)
      return nil if cmd.blank?

      ecosystem = ecosystem_name(provider)
      log("[dependency_audit] (#{ecosystem}) $ #{cmd}")

      tail = +""
      result = ProcessRunner.new(
        env: env,
        command: [ "bash", "-c", cmd ],
        chdir: workspace.path,
        timeout: PER_COMMAND_TIMEOUT,
        kind: "dependency_audit",
        run: run,
        workflow: workflow,
        on_output_chunk: ->(chunk) {
          append_output_tail(tail, chunk, max_bytes: OUTPUT_TAIL_BYTES)
          log(chunk, kind: "system")
        }
      ).run

      {
        "ecosystem"   => ecosystem,
        "command"     => cmd,
        "exit_status" => result.exit_status,
        "timed_out"   => result.timed_out?,
        "duration_s"  => result.duration_s&.round(2),
        "output_tail" => compact_output_tail(tail),
        "clean"       => result.success?
      }
    end

    def ecosystem_name(provider)
      provider.to_s.split("::").first
    end

    def store_artifact!(results)
      artifact = { "results" => results }
      formatted = DependencyAuditReport::PrCommentFormatter.new(artifact).format
      artifact["pr_comment_body"] = formatted if formatted.present?

      workflow.set_artifact!("dependency_audit", artifact)

      clean_count = results.count { |r| r["clean"] }
      log("[dependency_audit] scanned #{results.size} ecosystem(s), #{clean_count} clean, " \
          "#{results.size - clean_count} flagged: #{results.map { |r| r['ecosystem'] }.join(', ')}")
    end

    def env
      ProcessRunner.forwarded_env(Prepare::PREP_ENV_FORWARD, extra: workspace_dependency_env)
    end
  end
end
