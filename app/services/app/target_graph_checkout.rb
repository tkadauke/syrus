require "fileutils"
require "open3"
require "tmpdir"

module App
  class TargetGraphCheckout
    DEFAULT_REF = "HEAD".freeze

    def self.with_default_branch(repository:, user:)
      new(repository: repository, user: user).with_default_branch { |path| yield path }
    end

    def initialize(repository:, user:, git: GitRunner.new)
      @repository = repository
      @user = user
      @git = git
    end

    def with_default_branch
      clone = RepositoryBareClone.new(repository, git: git)
      clone.sync!(user: user)

      Dir.mktmpdir("target-graph-#{repository.id}-") do |dir|
        export_ref!(clone.path, repository.default_branch.presence || DEFAULT_REF, dir)
        yield Pathname.new(dir)
      end
    end

    private

    attr_reader :repository, :user, :git

    def export_ref!(clone_path, ref, destination)
      archive_path = File.join(destination, "repo.tar")
      run!("git", "--git-dir=#{clone_path}", "archive", "--format=tar", "-o", archive_path, ref)
      run!("tar", "-xf", archive_path, "-C", destination)
      FileUtils.rm_f(archive_path)
    rescue StandardError
      FileUtils.rm_f(archive_path)
      raise
    end

    def run!(*cmd)
      stdout, stderr, status = Open3.capture3(*cmd)
      return stdout if status.success?

      output = [ stdout, stderr ].join
      raise GitRunner::GitError.new(cmd, status.exitstatus || -1, output)
    end
  end
end
