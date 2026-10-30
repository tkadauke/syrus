require "fileutils"
require "tmpdir"

class Coworkers::RemoteWorkspace
  RefChanged = Class.new(StandardError)
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
      @git.run("push", authenticated_url, "HEAD:#{ref}", chdir: path)
      @git.run("push", authenticated_url, ":#{ref}", chdir: path)
    end
  end

  def seed!(branch:, files:, identity:)
    validate_coworker_namespace!(branch)
    with_seed_checkout do |path|
      files.each do |relative_path, content|
        absolute_path = File.join(path, relative_path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        write(path, relative_path, content)
      end
      commit!(path, identity, "Create @#{identity.git_email.split('@').first}'s coworker home")
      sha = @git.run("rev-parse", "HEAD", chdir: path).strip
      yield sha if block_given?
      @git.run("push", authenticated_url, "HEAD:refs/heads/#{branch}", chdir: path)
      sha
    end
  end

  def branch_sha(branch)
    validate_coworker_namespace!(branch)
    line = @git.run("ls-remote", "--heads", authenticated_url, "refs/heads/#{branch}").lines.first
    line&.split&.first
  end

  def copy!(source:, destination:, guard:)
    source = guard.allow!(source)
    destination = guard.allow!(destination)
    raise ArgumentError, "destination branch already exists" if branch_exists?(destination)

    raise ArgumentError, "source branch does not exist" unless branch_exists?(source)

    Dir.mktmpdir("syrus-coworker-ref-") do |path|
      @git.run("clone", "--branch", source, "--single-branch", "--no-tags", authenticated_url, path)
      @git.run("push", authenticated_url, "HEAD:refs/heads/#{destination}", chdir: path)
    end
  end

  def guarded_delete!(branch, guard:)
    delete!(guard.allow!(branch))
  end

  def delete!(branch)
    validate_coworker_namespace!(branch)
    with_seed_checkout do |path|
      @git.run("push", authenticated_url, ":refs/heads/#{branch}", chdir: path)
    end
  end

  # Deletes only when the server still has the commit we proved belongs to the
  # provisioning attempt. The explicit lease makes the proof and deletion one
  # atomic ref update at the remote.
  def delete_if_matches!(branch, expected_sha:)
    validate_coworker_namespace!(branch)
    ref = "refs/heads/#{branch}"
    with_seed_checkout do |path|
      @git.run("push", "--force-with-lease=#{ref}:#{expected_sha}", authenticated_url, ":#{ref}", chdir: path)
    end
  rescue GitRunner::GitError => error
    current = branch_sha(branch)
    return if current.nil? # Another cleanup already removed the proven ref.
    raise RefChanged, "the remote ref changed before cleanup could delete it" if current.present? && current != expected_sha
    raise
  end

  private

  def authenticated_url = repository.authenticated_url(user: @user)

  def validate_coworker_namespace!(branch)
    raise ArgumentError, "coworker pushes may only target refs under coworkers/" unless branch.to_s.start_with?("coworkers/")
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
