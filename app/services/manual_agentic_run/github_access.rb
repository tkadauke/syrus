require "base64"
require "fileutils"
require "open3"
require "socket"
require "tmpdir"

module ManualAgenticRun
  # Run-scoped broker. Agent-visible wrappers know only a local socket; the
  # credential and authoritative audit buffer remain in the worker process.
  class GithubAccess
    PERMISSIONS = { contents: "write", pull_requests: "write", issues: "write" }.freeze
    DESTRUCTIVE_GH = /\A(?:repo delete|pr close|issue close|release delete|api .*\s(?:-X|--method)\s+(?:DELETE|PUT))/i
    BLOCKED_GH = %w[auth alias extension config].freeze
    REPOSITORY_GH = %w[clone view edit delete fork sync archive rename].freeze
    REGISTRY = {}
    REGISTRY_MUTEX = Mutex.new

    def self.for(run) = new(run)

    def self.cleanup(run)
      REGISTRY_MUTEX.synchronize { REGISTRY.delete(run.id) }&.stop
      dir = run.step.workflow.artifact("manual_agentic_run_github_wrapper_dir")
      FileUtils.remove_entry_secure(dir) if dir.present? && File.directory?(dir)
      run.step.workflow.set_artifact!("manual_agentic_run_github_wrapper_dir", nil) if dir.present?
    rescue StandardError => e
      Rails.logger.warn("[ManualAgenticRun::GithubAccess] cleanup failed: #{e.class}: #{CommandRedactor.redact(e.message)}")
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
      socket_path = File.join(dir, "broker.sock")
      broker = Broker.new(socket_path:, token: grant.fetch(:token), expires_at: grant.fetch(:expires_at), repository: @repository.slug,
        destructive: @workflow.artifact("manual_agentic_run_github_destructive") == true,
        commands: { "gh" => real_command("gh"), "git" => real_command("git") }).start
      self.class::REGISTRY_MUTEX.synchronize do
        raise "break-glass GitHub broker already exists for Run #{@run.id}" if self.class::REGISTRY.key?(@run.id)
        self.class::REGISTRY[@run.id] = broker
      end
      %w[gh git].each { |name| write_wrapper(dir, name, socket_path) }
      @workflow.set_artifact!("manual_agentic_run_github_wrapper_dir", dir)
      @workflow.set_artifact!("manual_agentic_run_github_credential_expires_at", grant.fetch(:expires_at).iso8601)
      { "PATH" => "#{dir}:#{ENV.fetch('PATH', '')}", "GH_HOST" => "github.com", "GH_REPO" => @repository.slug,
        "SYRUS_GITHUB_REPOSITORY" => @repository.slug }
    rescue StandardError
      broker&.stop
      FileUtils.remove_entry_secure(dir) if dir.present? && File.directory?(dir)
      raise
    end

    def collect_audit!
      broker = self.class::REGISTRY_MUTEX.synchronize { self.class::REGISTRY[@run.id] }
      entries = broker&.audit_entries || []
      @workflow.set_artifact!("manual_agentic_run_github_audit", entries.map { |entry| entry.merge("actor_user_id" => @job.user_id, "repository" => @repository.slug) })
      entries
    end

    private

    def real_command(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |part| File.join(part, name) }.find { |path| File.file?(path) && File.executable?(path) } || raise(ArgumentError, "#{name} is unavailable on this worker")
    end

    def write_wrapper(dir, name, socket_path)
      source = <<~RUBY
        #!/usr/bin/env ruby
        require "json"; require "socket"
        socket = UNIXSocket.new(#{socket_path.inspect})
        socket.puts(JSON.generate(command: #{name.inspect}, args: ARGV, cwd: Dir.pwd))
        response = JSON.parse(socket.read)
        $stdout.write(response.fetch("stdout", "")); $stderr.write(response.fetch("stderr", ""))
        exit Integer(response.fetch("exit_status", 1))
      RUBY
      File.write(File.join(dir, name), source, mode: "w", perm: 0o700)
    end

    class Broker
      def initialize(socket_path:, token:, expires_at:, repository:, destructive:, commands:)
        @socket_path, @token, @expires_at, @repository = socket_path, token, expires_at, repository
        @destructive, @commands = destructive, commands
        @audit_entries, @audit_mutex = [], Mutex.new
      end

      def start
        @server = UNIXServer.new(@socket_path)
        File.chmod(0o600, @socket_path)
        @thread = Thread.new { serve }
        self
      end

      def stop
        @server&.close
        @thread&.join(1)
      rescue IOError, Errno::EBADF
        nil
      ensure
        @token = nil
      end

      def audit_entries = @audit_mutex.synchronize { @audit_entries.map(&:dup) }

      private

      def serve
        loop do
          client = @server.accept
          request = JSON.parse(client.gets.to_s)
          client.write(JSON.generate(execute(request)))
        rescue IOError, Errno::EBADF
          break
        rescue StandardError => e
          client&.write(JSON.generate(stdout: "", stderr: "Syrus GitHub broker rejected the request: #{e.message}\n", exit_status: rejection_status(e)))
        ensure
          client&.close
        end
      end

      def rejection_status(error)
        error.message.include?("restricted") ? 77 : (error.message.include?("destructive") ? 78 : 79)
      end

      def execute(request)
        raise "scoped GitHub credential expired" unless @expires_at > Time.current
        name, args = request.fetch("command"), Array(request.fetch("args")).map(&:to_s)
        raise "unsupported command" unless @commands.key?(name)
        validate!(name, args)
        started = Time.now.utc.iso8601
        stdout, stderr, status = Open3.capture3(command_environment(name), @commands.fetch(name), *args, chdir: request.fetch("cwd"))
        record(name, args, stdout, status, started)
        { stdout:, stderr:, exit_status: status.exitstatus }
      end

      def validate!(name, args)
        joined = args.join(" ")
        refs = repo_refs(args)
        raise "access is restricted to #{@repository}" if refs.any? { |candidate| !candidate.sub(/\.git\z/, "").casecmp?(@repository) }
        if name == "git"
          raise "this git command is unavailable in scoped break-glass mode" if args.first == "credential" || joined.match?(/(?:^|\s)-c\s+alias\./)
          return
        end
        raise "this gh command is unavailable in scoped break-glass mode" if BLOCKED_GH.include?(args.first)
        explicit = args.each_index.filter_map { |i| args[i + 1] if %w[-R --repo].include?(args[i]) }.compact
        explicit << args[2] if args.first == "repo" && REPOSITORY_GH.include?(args[1]) && args[2].to_s.include?("/")
        raise "access is restricted to #{@repository}" if explicit.any? { |candidate| !candidate.casecmp?(@repository) }
        validate_api!(args) if args.first == "api"
        raise "this destructive GitHub operation requires separately confirmed destructive authority" if joined.match?(DESTRUCTIVE_GH) && !@destructive
      end

      def validate_api!(args)
        endpoint = args.drop(1).find { |arg| arg.start_with?("/", "repos/") }.to_s.delete_prefix("/")
        raise "GitHub API access is restricted to repos/#{@repository}" unless endpoint == "repos/#{@repository}" || endpoint.start_with?("repos/#{@repository}/")
      end

      def repo_refs(args) = args.filter_map { |arg| arg[%r{(?:github\.com[:/]|repos/)([^/\s]+/[^/\s]+)}, 1] }

      def command_environment(name)
        return { "GH_TOKEN" => @token, "GH_HOST" => "github.com", "GH_REPO" => @repository } if name == "gh"
        basic = Base64.strict_encode64("x-access-token:#{@token}")
        { "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraheader",
          "GIT_CONFIG_VALUE_0" => "Authorization: Basic #{basic}", "GIT_TERMINAL_PROMPT" => "0" }
      end

      def record(name, args, stdout, status, started)
        entry = { "category" => name == "git" ? (args.first == "push" ? "git_push" : "git_read_or_local") : "gh_#{args.first || 'unknown'}",
          "operation" => name == "gh" ? args.first(2) : args.first(1), "targets" => repo_refs(args), "started_at" => started,
          "finished_at" => Time.now.utc.iso8601, "result" => status.success? ? "succeeded" : "failed", "exit_status" => status.exitstatus,
          "provider_object_identifiers" => stdout.scan(%r{https://github\.com/[^\s]+|\b[0-9a-f]{40}\b}).uniq }
        @audit_mutex.synchronize { @audit_entries << entry }
      end
    end
  end
end
