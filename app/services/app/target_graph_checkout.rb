require "fileutils"
require "tmpdir"

module App
  class TargetGraphCheckout
    DEFAULT_REF = "HEAD".freeze

    def self.with_default_branch(repository:, user:)
      new(repository: repository, user: user).with_default_branch { |path| yield path }
    end

    def self.with_ref(repository:, user:, ref:)
      new(repository: repository, user: user).with_ref(ref) { |path| yield path }
    end

    def initialize(repository:, user:, git: GitRunner.new)
      @repository = repository
      @user = user
      @git = git
    end

    def with_default_branch
      with_ref(repository.default_branch.presence || DEFAULT_REF) { |path| yield path }
    end

    def with_ref(ref)
      clone = RepositoryBareClone.new(repository, git: git)
      clone.sync!(user: user)
      fetch_remote_ref!(clone.path, ref) if remote_ref?(ref)

      Dir.mktmpdir("target-graph-#{repository.id}-") do |dir|
        export_ref!(clone.path, ref.presence || DEFAULT_REF, dir)
        yield Pathname.new(dir)
      end
    end

    private

    attr_reader :repository, :user, :git

    def remote_ref?(ref)
      ref.to_s.start_with?("refs/")
    end

    def fetch_remote_ref!(clone_path, ref)
      GithubAuthenticatedGit.run(
        repository: repository,
        user: user,
        git: git,
        operation_type: "git_target_graph_fetch_ref"
      ) do |url|
        git.run(
          "fetch",
          url,
          "+#{ref}:#{ref}",
          chdir: clone_path.to_s,
          env: { "GIT_TERMINAL_PROMPT" => "0" }
        )
      end
    end

    def export_ref!(clone_path, ref, destination)
      archive_path = File.join(destination, "repo.tar")
      git.run("--git-dir=#{clone_path}", "archive", "--format=tar", "-o", archive_path, ref,
        chdir: destination)
      run_archive!("tar", "-xf", archive_path, "-C", destination, chdir: destination)
      FileUtils.rm_f(archive_path)
    rescue StandardError
      FileUtils.rm_f(archive_path)
      raise
    end

    def run_archive!(*cmd, chdir:)
      capture = ProcessRunner.new(
        env: {}, command: cmd, mounts: ProcessRunner.mounts(chdir), network: "grader",
        timeout: GitRunner::DEFAULT_TIMEOUT, kind: "archive"
      ).capture
      return capture.stdout if capture.success?

      output = capture.stdout + capture.stderr
      raise GitRunner::GitError.new(cmd, capture.result.exit_status || -1, output)
    end
  end
end
