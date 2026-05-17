require "rails_helper"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe AutoRebase do
  # Build a real bare repo on the local filesystem to play the role of
  # github.com — push lands here, exercising the full clone/rebase/push
  # plumbing without leaving the box.
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-bare")) }
  let(:syrus_data_root) { Pathname.new(Dir.mktmpdir("syrus-data")) }
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(
      user: user, owner: "acme", name: "widgets",
      default_branch: "main", trigger_label: "syrus", polling_enabled: true
    )
  end
  let(:job) do
    Factories.job(repository: repository, issue_number: 42).tap do |j|
      j.update!(branch_name: "syrus/issue-42-#{j.id}")
    end
  end

  before(:context) do
    @seed_bare_remote_dir = Pathname.new(Dir.mktmpdir("syrus-rebase-bare-seed"))
    seed_remote(@seed_bare_remote_dir)
  end

  after(:context) do
    FileUtils.rm_rf(@seed_bare_remote_dir) if @seed_bare_remote_dir
  end

  before do
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.cp_r(@seed_bare_remote_dir.to_s, bare_remote_dir.to_s)
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")
    ENV["SYRUS_DATA_ROOT"] = syrus_data_root.to_s
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(syrus_data_root)
  end

  it "force-pushes a deterministic rebase when there are no conflicts" do
    # Make a feature branch with one commit, then advance main with a
    # disjoint commit so the feature branch is "behind".
    feature = "syrus/issue-42-#{job.id}"
    push_branch_with_file(feature, "feature.rb", "FEATURE\n", "feature commit")
    push_main_advance("README.md", "README\n", "main moves forward")

    result = described_class.new(job).call
    expect(result).to be_succeeded
    expect(result.reason).to eq("rebased")

    # Branch on origin should now contain BOTH the README and feature.rb
    files = `git --git-dir=#{bare_remote_dir} ls-tree --name-only #{feature}`.split("\n")
    expect(files).to include("feature.rb").and include("README.md")
  end

  it "is a no-op when the branch is already up-to-date with base" do
    feature = "syrus/issue-42-#{job.id}"
    push_branch_with_file(feature, "feature.rb", "FEATURE\n", "feature")

    result = described_class.new(job).call
    expect(result).to be_succeeded
    expect(result.note).to match(/no-op/)
  end

  it "rebases onto the parent branch when the Job is stacked" do
    parent = Factories.job(repository: repository, issue_number: 41)
    parent_branch = "syrus/issue-41-#{parent.id}"
    feature = "syrus/issue-42-#{job.id}"
    push_branch_with_file(parent_branch, "parent.rb", "PARENT\n", "parent")
    parent_sha = `git --git-dir=#{bare_remote_dir} rev-parse #{parent_branch}`.strip
    parent.update!(branch_name: parent_branch, pr_number: 41)
    parent.runs.create!(trigger_kind: "initial", agent_provider: parent.agent_provider, head_sha: parent_sha)
    JobDependency.create!(job: job, depends_on_job: parent, source: "manual", created_by_user: user)
    push_branch_with_file(feature, "feature.rb", "FEATURE\n", "feature")

    result = described_class.new(job).call

    expect(result).to be_succeeded
    files = `git --git-dir=#{bare_remote_dir} ls-tree --name-only #{feature}`.split("\n")
    expect(files).to include("feature.rb").and include("parent.rb")
  end

  it "returns conflict and does not push when a real body conflict remains" do
    feature = "syrus/issue-42-#{job.id}"
    push_branch_with_file(feature, "shared.rb", "FROM_FEATURE\n", "feature edit")
    push_main_advance("shared.rb", "FROM_MAIN\n", "main edit")

    pre_branch_sha = `git --git-dir=#{bare_remote_dir} rev-parse #{feature}`.strip

    result = described_class.new(job).call
    expect(result).not_to be_succeeded
    expect(result.reason).to eq("conflict")

    # Branch on origin must be unchanged — we did NOT force-push a
    # half-rebased branch.
    expect(`git --git-dir=#{bare_remote_dir} rev-parse #{feature}`.strip).to eq(pre_branch_sha)
  end

  it "registers merge drivers declared in the target repo's .gitattributes and succeeds" do
    feature = "syrus/issue-42-#{job.id}"

    # Seed the feature branch with a .gitattributes referencing a custom
    # merge driver and an executable bin/merge-pet driver script.
    Dir.mktmpdir("syrus-driver-seed") do |seed|
      sh("git init -q -b main #{seed}")
      File.write(File.join(seed, ".gitattributes"), "config/secrets.yml merge=pet\n")
      FileUtils.mkdir_p(File.join(seed, "bin"))
      script = File.join(seed, "bin", "merge-pet")
      File.write(script, "#!/usr/bin/env bash\nexec git merge-file \"$2\" \"$1\" \"$3\"\n")
      File.chmod(0o755, script)
      sh("git -C #{seed} add .gitattributes bin/merge-pet")
      sh("git -C #{seed} -c user.email=t@e -c user.name=t commit -q -m 'driver setup'")
      sh("git -C #{seed} push -q #{bare_remote_dir} HEAD:refs/heads/#{feature}")
    end

    # AutoRebase clones the branch itself; verify it can complete without
    # raising an error when merge drivers are present.
    result = described_class.new(job).call
    expect(result).to be_succeeded
  end

  describe "early exits" do
    it "no_branch when the Job has no branch_name" do
      job.update_columns(branch_name: nil)
      expect(described_class.new(job).call.reason).to eq("no_branch")
    end
  end

  # ---- helpers --------------------------------------------------------

  def seed_remote(bare_path)
    Dir.mktmpdir("seed") do |seed|
      sh("git init -q -b main #{seed}")
      sh("git -C #{seed} commit --allow-empty -q -m 'initial'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
    end
  end

  def push_branch_with_file(branch, file, content, message)
    Dir.mktmpdir("push") do |w|
      sh("git clone -q file://#{bare_remote_dir} #{w}")
      sh("git -C #{w} checkout -q -b #{branch}")
      File.write(File.join(w, file), content)
      sh("git -C #{w} add .")
      sh("git -C #{w} -c user.email=t@e -c user.name=t commit -q -m '#{message}'")
      sh("git -C #{w} push -q origin #{branch}")
    end
  end

  def push_main_advance(file, content, message)
    Dir.mktmpdir("push-main") do |w|
      sh("git clone -q file://#{bare_remote_dir} #{w}")
      File.write(File.join(w, file), content)
      sh("git -C #{w} add .")
      sh("git -C #{w} -c user.email=t@e -c user.name=t commit -q -m '#{message}'")
      sh("git -C #{w} push -q origin main")
    end
  end

  def sh(cmd)
    out, err, status = Open3.capture3({ "GIT_AUTHOR_NAME" => "T", "GIT_AUTHOR_EMAIL" => "t@e",
                                        "GIT_COMMITTER_NAME" => "T", "GIT_COMMITTER_EMAIL" => "t@e" }, cmd)
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
