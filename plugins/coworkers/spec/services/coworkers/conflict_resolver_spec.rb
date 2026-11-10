require "rails_helper"
require "tmpdir"

RSpec.describe Coworkers::ConflictResolver, :allow_host_execution do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:result_class) { Struct.new(:timed_out, :is_error, :exit_status, :final_text) { def success? = true } }

  before do
    @dir = Pathname(Dir.mktmpdir("conflict-resolver-spec-"))
    git("init", "--initial-branch=main", ".")
    git("config", "user.name", "Maya")
    git("config", "user.email", "maya@example.test")
    write("SOUL.md", "voice: concise\n")
    write("notes.md", "a\nb\nc\n")
    write("config.yml", "k: 1\n")
    git("add", ".")
    git("commit", "-m", "base")
    git("checkout", "-b", "source")
    write("notes.md", "a\nSOURCE\nc\n")
    git("commit", "-am", "source")
    git("checkout", "main")
    write("notes.md", "a\nHOME\nc\n")
    git("commit", "-am", "home")
    expect { git("merge", "--no-edit", "source") }.to raise_error(/CONFLICT|exit/)
  end

  after do
    described_class.agent = nil
    FileUtils.rm_rf(@dir)
  end

  def git(*args)
    out, err, status = Open3.capture3("git", *args, chdir: @dir.to_s)
    raise "git #{args.join(' ')} failed: #{out}#{err}" unless status.success?
    out
  end

  def write(relative, content) = @dir.join(relative).write(content)
  def ok = result_class.new(false, false, 0, "done")
  def resolver = described_class.new(coworker:, user: owner)

  it "recovers on a later attempt, passes the rejection reason back, and commits a two-parent merge" do
    prompts = []
    described_class.agent = lambda do |workspace_path:, prompt:|
      prompts << prompt
      content = prompts.size == 1 ? "a\n<<<<<<< HEAD\nHOME\n=======\nSOURCE\n>>>>>>> source\nc\n" : "a\nHOME\nSOURCE\nc\n"
      Pathname(workspace_path).join("notes.md").write(content)
      ok
    end

    outcome = resolver.call(dir: @dir)

    expect(outcome).to be_resolved
    expect(outcome.attempts).to eq(2)
    expect(prompts.first).to include("notes.md", "voice: concise", "HOME", "SOURCE")
    expect(prompts.last).to include("Conflict markers remain in notes.md")
    expect(@dir.join("notes.md").read).to eq("a\nHOME\nSOURCE\nc\n")
    expect(git("log", "-1", "--format=%P").split.size).to eq(2)
  end

  it "rejects a lone opening marker or lone closing marker" do
    [ "a\n<<<<<<< HEAD\nHOME\nc\n", "a\nHOME\n>>>>>>> source\nc\n" ].each do |bad|
      described_class.agent = lambda do |workspace_path:, prompt:|
        Pathname(workspace_path).join("notes.md").write(bad)
        ok
      end
      outcome = resolver.call(dir: @dir)
      expect(outcome).not_to be_resolved
      expect(outcome.detail).to include("Conflict markers remain in notes.md")
    end
  end

  it "runs git diff --check across non-conflicting files the agent touched" do
    described_class.agent = lambda do |workspace_path:, prompt:|
      Pathname(workspace_path).join("notes.md").write("a\nHOME\nSOURCE\nc\n")
      Pathname(workspace_path).join("SOUL.md").write("voice: concise   \n")
      ok
    end

    outcome = resolver.call(dir: @dir)

    expect(outcome).not_to be_resolved
    expect(outcome.detail).to include("git diff --check failed", "SOUL.md")
  end

  it "rejects a structured file that no longer parses" do
    described_class.agent = lambda do |workspace_path:, prompt:|
      Pathname(workspace_path).join("notes.md").write("a\nHOME\nSOURCE\nc\n")
      Pathname(workspace_path).join("config.yml").write("k: [unterminated\n")
      ok
    end

    outcome = resolver.call(dir: @dir)

    expect(outcome).not_to be_resolved
    expect(outcome.detail).to include("Structured files no longer parse: config.yml")
  end

  it "reports agent failures and leaves unmerged entries unresolved" do
    described_class.agent = ->(workspace_path:, prompt:) { result_class.new(true, false, nil, nil) }
    outcome = resolver.call(dir: @dir)
    expect(outcome).not_to be_resolved
    expect(outcome.detail).to include("Conflict markers remain").or include("timed out")
    expect(outcome.attempts).to eq(described_class::MAX_ATTEMPTS)
  end

  it "reads stage versions and reports a missing stage" do
    expect(resolver.send(:stage, @dir, 2, "notes.md")).to include("HOME")
    expect(resolver.send(:stage, @dir, 3, "notes.md")).to include("SOURCE")
    expect(resolver.send(:stage, @dir, 1, "missing.md")).to eq("(absent in this version)")
  end

  describe "#available?" do
    it "is true when the test seam is set" do
      described_class.agent = ->(**) { ok }
      expect(resolver).to be_available
    end

    it "is false without an agent provider" do
      user = instance_double(User, agent_provider: nil)
      expect(described_class.new(coworker:, user:)).not_to be_available
    end

    it "is false when the provider is not configured" do
      user = instance_double(User, agent_provider: "claude", agent_provider_configured?: false)
      expect(described_class.new(coworker:, user:)).not_to be_available
    end

    it "is true when the provider is configured" do
      user = instance_double(User, agent_provider: "claude", agent_provider_configured?: true)
      expect(described_class.new(coworker:, user:)).to be_available
    end
  end
end
