require "fileutils"
require "tmpdir"

class Coworkers::RemoteWorkspace
  attr_reader :repository

  def initialize(owner:, name:, user:, git: GitRunner.new)
    @repository = Repository.new(owner: owner, name: name, user: user)
    @user = user
    @git = git
  end

  def branch_exists?(branch)
    @git.run("ls-remote", "--heads", authenticated_url, "refs/heads/#{branch}").present?
  end

  def test_push_access!
    with_seed_checkout do |path|
      write(path, "access-check", "Syrus coworker workspace access check\n")
      commit!(path, Coworkers::GitIdentity.new(name: "Syrus", handle: "access-check"), "Test coworker workspace access")
      ref = "refs/heads/coworkers/access-check-#{SecureRandom.hex(8)}"
      push!("HEAD:#{ref}", chdir: path)
      push!(":#{ref}")
    end
  end

  def seed!(branch:, files:, identity:)
    with_seed_checkout do |path|
      files.each do |relative_path, content|
        absolute_path = File.join(path, relative_path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        write(path, relative_path, content)
      end
      commit!(path, identity, "Create @#{identity.git_email.split('@').first}'s coworker home")
      push!("HEAD:refs/heads/#{branch}", chdir: path, home_branch: branch)
    end
  end

  def copy!(from:, to:, coworker:)
    raise ArgumentError, "coworker branch already exists: #{to}" if branch_exists?(to)

    Dir.mktmpdir("syrus-coworker-move-") do |path|
      @git.run("init", "--initial-branch=coworker-move", path)
      @git.run("fetch", authenticated_url, "refs/heads/#{from}:refs/remotes/origin/coworker-home", chdir: path)
      push!("refs/remotes/origin/coworker-home:refs/heads/#{to}", chdir: path, coworker: coworker, home_branch: to)
    end
  end

  def delete!(branch, coworker: nil, home_branch: nil)
    push!(":refs/heads/#{branch}", coworker: coworker, home_branch: home_branch || branch)
  end

  private

  def authenticated_url = repository.authenticated_url(user: @user)

  def push!(*refspecs, chdir: nil, coworker: nil, home_branch: nil)
    Coworkers::PushGuard.new(coworker: coworker, home_branch: home_branch).validate!(*refspecs)
    @git.run("push", authenticated_url, *refspecs, chdir: chdir)
  end

  def with_seed_checkout
    Dir.mktmpdir("syrus-coworker-") do |path|
      @git.run("init", "--initial-branch=coworker-home", path)
      yield path
    end
  end

  def write(path, relative_path, content)
    File.binwrite(File.join(path, relative_path), content)
  end

  def commit!(path, identity, message)
    @git.configure_author(identity, chdir: path)
    @git.run("add", "--all", chdir: path)
    @git.run("commit", "-m", message, chdir: path)
  end
end
