require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Coworkers::WorkspaceCandidateValidator, :allow_host_execution do
  before do
    @path = Pathname(Dir.mktmpdir("workspace-candidate-validator-spec-"))
    run_git("init", "--initial-branch=main")
    run_git("config", "user.name", "Maya")
    run_git("config", "user.email", "maya@example.test")
    @path.join("README.md").write("safe\n")
    commit!("base")
    @base_sha = run_git("rev-parse", "HEAD").strip
  end

  after { FileUtils.rm_rf(@path) }

  def run_git(*args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: @path.to_s)
    raise stderr unless status.success?
    stdout
  end

  def commit!(message)
    run_git("add", "--all")
    run_git("commit", "-m", message)
  end

  def validate! = described_class.new(@path).validate!(base_sha: @base_sha)

  it "rejects invalid changed JSON and YAML" do
    @path.join("settings.json").write("{broken\n")
    @path.join("settings.yml").write("key: [broken\n")
    commit!("invalid structured data")
    expect { validate! }.to raise_error(described_class::ValidationError, /settings\.(?:json|yml) is invalid/)
  end

  it "rejects diff-check errors" do
    @path.join("README.md").write("trailing whitespace \n")
    commit!("bad whitespace")
    expect { validate! }.to raise_error(described_class::ValidationError, /git diff --check rejected.*trailing whitespace/m)
  end

  it "rejects invalid JSON in a pathname containing a newline" do
    relative = "unusual\nname.json"
    @path.join(relative).write("{broken\n")
    git = instance_double(GitRunner)
    allow(git).to receive(:run).with("diff", "--name-only", "-z", "--diff-filter=U", chdir: @path.to_s).and_return("")
    allow(git).to receive(:capture).and_return(instance_double(ProcessRunner::CaptureResult, success?: true))
    allow(git).to receive(:run)
      .with("diff", "--name-only", "-z", "--diff-filter=ACMR", @base_sha, "HEAD", chdir: @path.to_s)
      .and_return("#{relative}\0")
    expect { described_class.new(@path, git:).validate!(base_sha: @base_sha) }
      .to raise_error(described_class::ValidationError, /unusual\nname\.json is invalid/)
  end

  it "rejects unmerged index entries from NUL-delimited Git output" do
    git = instance_double(GitRunner)
    allow(git).to receive(:run).with("diff", "--name-only", "-z", "--diff-filter=U", chdir: @path.to_s)
      .and_return("one\ntwo.md\0")
    expect { described_class.new(@path, git:).validate!(base_sha: @base_sha) }
      .to raise_error(described_class::ValidationError, /unmerged index entries remain in one\ntwo\.md/)
  end

  it "does not parse binary files or follow changed symlinks" do
    @path.join("binary.json").binwrite("\x00{broken")
    File.symlink("README.md", @path.join("linked.json"))
    commit!("opaque files")
    expect(validate!).to be(true)
  end

  it "turns unsafe Git paths into validation failures" do
    git = instance_double(GitRunner)
    allow(git).to receive(:run).with("diff", "--name-only", "-z", "--diff-filter=U", chdir: @path.to_s).and_return("")
    allow(git).to receive(:capture).and_return(instance_double(ProcessRunner::CaptureResult, success?: true))
    allow(git).to receive(:run)
      .with("diff", "--name-only", "-z", "--diff-filter=ACMR", @base_sha, "HEAD", chdir: @path.to_s)
      .and_return("../outside.json\0")
    expect { described_class.new(@path, git:).validate!(base_sha: @base_sha) }
      .to raise_error(described_class::ValidationError, /cannot be validated safely/)
  end
end
