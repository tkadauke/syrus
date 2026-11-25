require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"

module ManualAgenticRun
  # Run-scoped command boundary for exceptional authenticated GitHub repair.
  # The credential exists only in the agent process environment and the
  # wrapper directory is removed as soon as that invocation returns.
  class GithubAccess
    PERMISSIONS = { contents: "write", pull_requests: "write", issues: "write" }.freeze
    DESTRUCTIVE_GH = /\A(?:repo delete|pr close|issue close|release delete|api .*\s-X\s+(?:DELETE|PUT))/i

    def self.for(run)
      new(run)
    end

    def self.cleanup(run)
      dir = run.step.workflow.artifact("manual_agentic_run_github_wrapper_dir")
      FileUtils.remove_entry_secure(dir) if dir.present? && File.directory?(dir)
      run.step.workflow.set_artifact!("manual_agentic_run_github_wrapper_dir", nil) if dir.present?
    rescue StandardError => e
      Rails.logger.warn("[ManualAgenticRun::GithubAccess] cleanup failed: #{e.class}: #{e.message}")
    end

    def initialize(run)
      @run = run
      @workflow = run.step.workflow
      @job = @workflow.job
      @repository = @job.repository
    end

    def enabled? = @workflow.artifact("manual_agentic_run_github_access") == true

    def environment
      return {} unless enabled?

      installation = @repository.installation
      raise ArgumentError, "break-glass GitHub access requires an active GitHub App installation" unless installation&.active? && installation.covers_repository?(@repository)
      raise ArgumentError, "repository GitHub id is required for scoped access" if @repository.github_repository_id.blank?

      grant = installation.scoped_token(repository: @repository, permissions: PERMISSIONS)
      raise ArgumentError, "scoped GitHub credential is already expired" unless grant.fetch(:expires_at) > Time.current
      dir = Dir.mktmpdir("syrus-github-run-#{@run.id}-")
      audit_path = File.join(dir, "audit.jsonl")
      token_path = File.join(dir, ".credential")
      File.write(token_path, grant.fetch(:token), mode: "w", perm: 0o600)
      askpass_path = File.join(dir, ".askpass")
      File.write(askpass_path, <<~SH, mode: "w", perm: 0o700)
        #!/bin/sh
        case "$1" in
          *Username*) printf '%s' 'x-access-token' ;;
          *) exec #{Shellwords.escape(RbConfig.ruby)} -e 'print File.binread(ARGV.fetch(0))' #{Shellwords.escape(token_path)} ;;
        esac
      SH
      write_wrapper(dir, "gh", real_command("gh"), audit_path, token_path, askpass_path)
      write_wrapper(dir, "git", real_command("git"), audit_path, token_path, askpass_path)
      @workflow.set_artifact!("manual_agentic_run_github_wrapper_dir", dir)
      @workflow.set_artifact!("manual_agentic_run_github_credential_expires_at", grant.fetch(:expires_at).iso8601)

      {
        "PATH" => "#{dir}:#{ENV.fetch('PATH', '')}",
        "GH_HOST" => "github.com",
        "GH_REPO" => @repository.slug,
        "SYRUS_GITHUB_REPOSITORY" => @repository.slug,
        "SYRUS_GITHUB_AUDIT_PATH" => audit_path,
        "SYRUS_GITHUB_DESTRUCTIVE" => (@workflow.artifact("manual_agentic_run_github_destructive") == true ? "1" : "0")
      }
    end

    def collect_audit!
      dir = @workflow.artifact("manual_agentic_run_github_wrapper_dir")
      path = File.join(dir.to_s, "audit.jsonl")
      entries = File.exist?(path) ? File.readlines(path, chomp: true).filter_map { |line| JSON.parse(line) rescue nil } : []
      @workflow.set_artifact!("manual_agentic_run_github_audit", entries.map { |entry|
        entry.merge("actor_user_id" => @job.user_id, "repository" => @repository.slug)
      })
      entries
    end

    private

    def real_command(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |part| File.join(part, name) }.find { |path| File.file?(path) && File.executable?(path) } ||
        raise(ArgumentError, "#{name} is unavailable on this worker")
    end

    def write_wrapper(dir, name, real, audit_path, token_path, askpass_path)
      path = File.join(dir, name)
      File.write(path, wrapper_source(name: name, real: real, audit_path: audit_path, token_path: token_path, askpass_path: askpass_path), mode: "w", perm: 0o700)
    end

    def wrapper_source(name:, real:, audit_path:, token_path:, askpass_path:)
      <<~RUBY
        #!/usr/bin/env ruby
        require "json"
        require "open3"
        require "time"
        repo = ENV.fetch("SYRUS_GITHUB_REPOSITORY")
        args = ARGV.dup
        joined = args.join(" ")
        repo_refs = args.filter_map { |arg| arg[%r{(?:github\\.com[:/]|repos/)([^/\\s]+/[^/\\s]+)}, 1] }
        if repo_refs.any? { |candidate| candidate.sub(/\\.git\\z/, "").casecmp?(repo) == false }
          warn "Syrus break-glass access is restricted to \#{repo}"
          exit 77
        end
        if #{name.inspect} == "gh"
          if %w[auth alias extension config].include?(args.first)
            warn "This gh command is unavailable in scoped break-glass mode"
            exit 79
          end
          explicit = args.each_index.filter_map { |i| args[i + 1] if %w[-R --repo].include?(args[i]) }.compact
          explicit << args[2] if args.first == "repo" && %w[clone view edit delete fork sync archive rename].include?(args[1]) && args[2].to_s.include?("/")
          if explicit.any? { |candidate| !candidate.casecmp?(repo) }
            warn "Syrus break-glass access is restricted to \#{repo}"
            exit 77
          end
          if args.first == "api"
            endpoint = args.find { |arg| arg.start_with?("/") || arg.start_with?("repos/") }.to_s.delete_prefix("/")
            unless endpoint.start_with?("repos/\#{repo}/") || endpoint == "repos/\#{repo}"
              warn "GitHub API access is restricted to repos/\#{repo}"
              exit 77
            end
          end
          destructive = joined.match?(#{DESTRUCTIVE_GH.inspect})
          if destructive && ENV["SYRUS_GITHUB_DESTRUCTIVE"] != "1"
            warn "This destructive GitHub operation requires separately confirmed destructive authority"
            exit 78
          end
        elsif args.first == "credential" || joined.match?(/(?:^|\s)-c\s+alias\./)
          warn "This git command is unavailable in scoped break-glass mode"
          exit 79
        end
        category = #{name.inspect} == "git" ? (args.first == "push" ? "git_push" : "git_read_or_local") : "gh_\#{args.first || 'unknown'}"
        started = Time.now.utc.iso8601 rescue Time.now.utc.to_s
        child_env = ENV.to_h.merge("GIT_ASKPASS" => #{askpass_path.inspect}, "GIT_TERMINAL_PROMPT" => "0")
        child_env["GH_TOKEN"] = File.binread(#{token_path.inspect}) if #{name.inspect} == "gh"
        stdout, stderr, status = Open3.capture3(child_env, #{real.inspect}, *args)
        $stdout.write(stdout); $stderr.write(stderr)
        operation = #{name.inspect} == "gh" ? args.first(2).reject { |arg| arg.start_with?("ghp_", "ghs_", "github_pat_") } : args.first(1)
        entry = { category: category, operation: operation, targets: repo_refs, started_at: started,
          finished_at: (Time.now.utc.iso8601 rescue Time.now.utc.to_s), result: status.success? ? "succeeded" : "failed",
          exit_status: status.exitstatus, provider_object_identifiers: stdout.scan(%r{https://github\\.com/[^\\s]+|\\b[0-9a-f]{40}\\b}).uniq }
        File.open(#{audit_path.inspect}, "a", 0600) { |file| file.puts(JSON.generate(entry)) }
        exit status.exitstatus
      RUBY
    end
  end
end
