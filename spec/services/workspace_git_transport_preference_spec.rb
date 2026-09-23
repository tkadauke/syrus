require "rails_helper"

RSpec.describe WorkspaceGitTransportPreference do
  let(:repository) { Factories.repository }
  let(:user) { repository.user }
  let(:present_shas) { [] }

  let(:includer_class) do
    Class.new do
      include WorkspaceGitTransportPreference

      attr_accessor :present_shas

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
end
