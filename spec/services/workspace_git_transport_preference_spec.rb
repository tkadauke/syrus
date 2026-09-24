require "rails_helper"
require "tmpdir"

# Records every GitRunner#run-shaped call; raises GitRunner::GitError for the
# first `fail_times` calls, then succeeds -- lets clone/fetch specs simulate
# "the mirror attempt fails, the retry-after-register attempt also fails"
# without touching a real git process.
class WorkspaceGitTransportPreferenceSpecFakeGit
  attr_reader :calls

  def initialize(fail_times: 0)
    @calls = []
    @fail_times = fail_times
  end

  def run(*args, **kwargs)
    @calls << [ args, kwargs ]
    raise GitRunner::GitError.new(args, 1, "fatal: could not read") if @calls.size <= @fail_times

    "ok"
  end
end

RSpec.describe WorkspaceGitTransportPreference do
  let(:repository) { Factories.repository }
  let(:user) { repository.user }
  let(:present_shas) { [] }

  let(:includer_class) do
    Class.new do
      include WorkspaceGitTransportPreference

      attr_accessor :present_shas, :git

      def git_object_present?(sha)
        present_shas.include?(sha)
      end
    end
  end
  let(:includer) { includer_class.new.tap { |i| i.present_shas = present_shas } }

  def register_transport(url: "http://mirror/v1/repositories/1", env: { "A" => "b" }, register_calls: nil)
    transport = Object.new
    transport.define_singleton_method(:url) { url }
    transport.define_singleton_method(:env) { env }
    transport.define_singleton_method(:register!) { register_calls&.push(:called) }
    Syrus::PluginRegistry.register(:workspace_git_transport, Class.new do
      include Syrus::Plugin::WorkspaceGitTransport
      define_singleton_method(:available_for?) { |_repository| true }
      define_singleton_method(:build) { |repository:, user:| transport }
    end)
    transport
  end

  def git_error
    GitRunner::GitError.new(%w[fetch mirror], 1, "fatal: could not read")
  end

  it "returns false without calling op when no transport is registered" do
    calls = []
    result = includer.try_mirror_transport(repository: repository, user: user) { |*args| calls << args }

    expect(result).to be(false)
    expect(calls).to be_empty
  end

  it "returns true and calls op once with the transport's url and env when the first attempt succeeds" do
    register_calls = []
    transport = register_transport(register_calls: register_calls)
    calls = []

    result = includer.try_mirror_transport(repository: repository, user: user) { |url, env| calls << [ url, env ] }

    expect(result).to be(true)
    expect(calls).to eq([ [ transport.url, transport.env ] ])
    expect(register_calls).to be_empty
  end

  it "registers and retries once when the first attempt raises, then succeeds" do
    register_calls = []
    register_transport(register_calls: register_calls)
    attempts = 0

    result = includer.try_mirror_transport(repository: repository, user: user) do |_url, _env|
      attempts += 1
      raise git_error if attempts == 1
    end

    expect(result).to be(true)
    expect(attempts).to eq(2)
    expect(register_calls).to eq([ :called ])
  end

  it "returns false when both the initial attempt and the post-register retry raise" do
    register_calls = []
    register_transport(register_calls: register_calls)
    attempts = 0

    result = includer.try_mirror_transport(repository: repository, user: user) do |_url, _env|
      attempts += 1
      raise git_error
    end

    expect(result).to be(false)
    expect(attempts).to eq(2)
    expect(register_calls).to eq([ :called ])
  end

  it "returns false when reactive transport registration is unavailable" do
    transport = register_transport
    allow(transport).to receive(:register!).and_raise(
      RepositoryContent::Unavailable,
      "git mirror: missing or invalid token"
    )
    attempts = 0

    result = includer.try_mirror_transport(repository: repository, user: user) do |_url, _env|
      attempts += 1
      raise git_error
    end

    expect(result).to be(false)
    expect(attempts).to eq(1)
  end

  describe "verify_sha" do
    it "returns true immediately when the wanted commit is already present after the first attempt" do
      register_transport
      present_shas << "deadbeef"
      attempts = 0

      result = includer.try_mirror_transport(repository: repository, user: user, verify_sha: "deadbeef") do |_url, _env|
        attempts += 1
      end

      expect(result).to be(true)
      expect(attempts).to eq(1)
    end

    it "retries and ultimately returns false when the wanted commit never shows up (a stale mirror)" do
      register_transport
      attempts = 0

      result = includer.try_mirror_transport(repository: repository, user: user, verify_sha: "deadbeef") do |_url, _env|
        attempts += 1
      end

      expect(result).to be(false)
      expect(attempts).to eq(2)
    end
  end

  describe "#clone_via_transport!" do
    let(:dest) { Pathname.new(Dir.mktmpdir("workspace-git-transport-clone")) }

    after { FileUtils.rm_rf(dest.to_s) }

    it "clears dest and calls fallback directly when no transport is registered" do
      includer.git = WorkspaceGitTransportPreferenceSpecFakeGit.new
      FileUtils.touch(dest.join("stale").to_s)
      fallback_calls = 0

      includer.clone_via_transport!(repository: repository, user: user, dest: dest, clone_args: [ "--branch", "main" ]) do
        fallback_calls += 1
      end

      expect(fallback_calls).to eq(1)
      expect(includer.git.calls).to be_empty
      expect(dest).not_to exist
    end

    it "clones via the mirror, merging the transport's env over the caller's, without calling fallback" do
      register_transport(url: "http://mirror/v1/repositories/1", env: { "A" => "mirror", "B" => "mirror" })
      includer.git = WorkspaceGitTransportPreferenceSpecFakeGit.new
      fallback_calls = 0

      includer.clone_via_transport!(
        repository: repository, user: user, dest: dest,
        clone_args: [ "--branch", "main", "--no-tags" ], env: { "A" => "caller" }
      ) { fallback_calls += 1 }

      expect(fallback_calls).to eq(0)
      expect(includer.git.calls.size).to eq(1)
      args, kwargs = includer.git.calls.first
      expect(args).to eq([ "clone", "--branch", "main", "--no-tags", "http://mirror/v1/repositories/1", dest.to_s ])
      expect(kwargs[:env]).to eq("A" => "mirror", "B" => "mirror")
    end

    it "clears dest before each mirror attempt and falls back after both fail" do
      register_transport
      includer.git = WorkspaceGitTransportPreferenceSpecFakeGit.new(fail_times: 2)
      FileUtils.touch(dest.join("stale").to_s)
      fallback_dest_existed = true

      includer.clone_via_transport!(repository: repository, user: user, dest: dest, clone_args: [ "--branch", "main" ]) do
        fallback_dest_existed = dest.exist?
      end

      expect(includer.git.calls.size).to eq(2)
      expect(fallback_dest_existed).to be(false)
    end

    it "falls back when mirror registration is unavailable" do
      transport = register_transport
      allow(transport).to receive(:register!).and_raise(
        RepositoryContent::Unavailable,
        "git mirror: missing or invalid token"
      )
      includer.git = WorkspaceGitTransportPreferenceSpecFakeGit.new(fail_times: 1)
      fallback_calls = 0

      includer.clone_via_transport!(
        repository: repository,
        user: user,
        dest: dest,
        clone_args: [ "--branch", "main" ]
      ) { fallback_calls += 1 }

      expect(fallback_calls).to eq(1)
    end
  end

  describe "#fetch_via_transport!" do
    let(:refspec) { "refs/heads/main:refs/heads/main" }

    it "calls fallback directly when no transport is registered" do
      includer.git = WorkspaceGitTransportPreferenceSpecFakeGit.new
      fallback_calls = 0

      includer.fetch_via_transport!(repository: repository, user: user, refspec: refspec, chdir: "/tmp") do
        fallback_calls += 1
      end

      expect(fallback_calls).to eq(1)
      expect(includer.git.calls).to be_empty
    end

    it "fetches via the mirror and skips fallback once verify_sha is present" do
      register_transport(url: "http://mirror/v1/repositories/1", env: { "A" => "b" })
      includer.git = WorkspaceGitTransportPreferenceSpecFakeGit.new
      present_shas << "deadbeef"
      fallback_calls = 0

      includer.fetch_via_transport!(
        repository: repository, user: user, refspec: refspec, chdir: "/tmp", verify_sha: "deadbeef"
      ) { fallback_calls += 1 }

      expect(fallback_calls).to eq(0)
      args, kwargs = includer.git.calls.first
      expect(args).to eq([ "fetch", "http://mirror/v1/repositories/1", refspec ])
      expect(kwargs).to eq(chdir: "/tmp", env: { "A" => "b" })
    end

    it "falls back when the wanted commit never shows up on the mirror (a stale mirror)" do
      register_transport
      includer.git = WorkspaceGitTransportPreferenceSpecFakeGit.new
      fallback_calls = 0

      includer.fetch_via_transport!(
        repository: repository, user: user, refspec: refspec, chdir: "/tmp", verify_sha: "deadbeef"
      ) { fallback_calls += 1 }

      expect(fallback_calls).to eq(1)
      expect(includer.git.calls.size).to eq(2)
    end
  end
end
