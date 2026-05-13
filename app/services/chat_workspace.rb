require "fileutils"

# Persistent per-Repository checkout used by repo chat inspection.
# Unlike WorkflowWorkspace, this workspace is long-lived and is not
# reset between turns.
class ChatWorkspace
  CLONE_DEPTH = 50
  EXCLUDE_ENTRY = ".syrus/".freeze

  def self.data_root
    Pathname.new(ENV["SYRUS_DATA_ROOT"] || File.expand_path("~/.syrus"))
  end

  def self.path_for(repository)
    data_root.join("chats", repository.id.to_s)
  end

  def self.ensure!(repository)
    new(repository).ensure!
  end

  def self.refresh!(repository)
    new(repository).refresh!
  end

  def self.reset!(repository)
    new(repository).reset!
  end

  def self.destroy!(repository)
    FileUtils.rm_rf(path_for(repository).to_s)
  end

  def initialize(repository, git: nil)
    @repository = repository
    @git = git || GitRunner.new
    @path = self.class.path_for(repository)
    @env = { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def ensure!
    return @path if @path.exist?

    FileUtils.mkdir_p(@path.dirname)
    @git.run(
      "clone", "--depth", CLONE_DEPTH.to_s,
      "--branch", @repository.default_branch,
      "--no-tags", authenticated_url, @path.to_s,
      env: @env
    )
    @git.run("remote", "set-url", "origin", @repository.remote_url, chdir: @path.to_s)
    GitInfoExclude.ensure_entry!(@path, EXCLUDE_ENTRY)
    @path
  end

  def refresh!
    ensure!
    @git.run("fetch", "--all", "--prune", chdir: @path.to_s, env: @env)
    @path
  end

  def reset!
    self.class.destroy!(@repository)
    ensure!
  end

  private

  def authenticated_url
    token = GithubClient.for(repository: @repository, user: @repository.user).access_token
    @repository.authenticated_push_url(token)
  end
end
