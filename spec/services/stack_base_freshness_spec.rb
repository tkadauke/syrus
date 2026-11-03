require "rails_helper"
require "tmpdir"

RSpec.describe StackBaseFreshness, :ci_only do
  let(:git) { GitRunner.new }
  let(:tmp) { Pathname.new(Dir.mktmpdir("stack-base-freshness")) }
  let(:remote) { tmp.join("remote.git") }
  let(:parent_clone) { tmp.join("parent") }
  let(:child) { tmp.join("child") }
  let(:workflow) { Workflow.create!(job: Factories.job, trigger_kind: "initial") }
  let(:parent_ref) { "syrus/parent" }

  after { FileUtils.rm_rf(tmp) }

  def sh(dir, *args) = git.run(*args, chdir: dir.to_s).strip

  def commit(dir, file, content = file)
    File.write(dir.join(file), content)
    sh(dir, "add", file)
    sh(dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "add #{file}")
    sh(dir, "rev-parse", "HEAD")
  end

  # Rebases the parent branch onto a new commit on main and force-pushes it,
  # the way a stack rebase moves a parent mid-run.
  def force_rebase_parent!(file = "main-#{SecureRandom.hex(3)}")
    sh(parent_clone, "checkout", "-q", "main")
    commit(parent_clone, file)
    sh(parent_clone, "push", "-q", "origin", "main")
    sh(parent_clone, "checkout", "-q", "parent")
    sh(parent_clone, "-c", "user.name=t", "-c", "user.email=t@example.com", "rebase", "main")
    sh(parent_clone, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{parent_ref}")
    sh(parent_clone, "rev-parse", "HEAD")
  end

  before do
    FileUtils.mkdir_p(tmp)
    sh(tmp, "init", "-q", "--bare", "-b", "main", remote.to_s)
    sh(tmp, "clone", "-q", remote.to_s, parent_clone.to_s)
    sh(parent_clone, "checkout", "-q", "-b", "main")
    commit(parent_clone, "base.txt")
    sh(parent_clone, "push", "-q", "origin", "main")
    sh(parent_clone, "checkout", "-q", "-b", "parent")
    commit(parent_clone, "parent.txt")
    sh(parent_clone, "push", "-q", "origin", "HEAD:refs/heads/#{parent_ref}")
    @prepared = sh(parent_clone, "rev-parse", "HEAD")

    # The child workspace is prepared from the parent head, then does its work.
    sh(tmp, "clone", "-q", "--branch", parent_ref, remote.to_s, child.to_s)
    sh(child, "config", "user.name", "t")
    sh(child, "config", "user.email", "t@example.com")
    sh(child, "checkout", "-q", "-b", "syrus/child")
    commit(child, "child.txt")
    described_class.record_prepared!(workflow, ref: parent_ref, sha: @prepared)
  end

  def fetch_live = -> {
    sh(child, "fetch", "-q", "origin", "+refs/heads/#{parent_ref}:refs/remotes/origin/#{parent_ref}")
    sh(child, "rev-parse", "refs/remotes/origin/#{parent_ref}")
  }

  def barrier(fetch: fetch_live, validator: -> { true }, **opts)
    described_class.new(workflow: workflow, git: git, path: child, parent_ref: parent_ref,
                        fetch_live: fetch, validator: validator, **opts)
  end

  def child_files = sh(child, "ls-tree", "-r", "--name-only", "HEAD").split("\n")

  it "passes through untouched when the parent did not move" do
    head = sh(child, "rev-parse", "HEAD")

    result = barrier.ensure_fresh!

    expect(result.status).to eq(:fresh)
    expect(result).not_to be_rebased
    expect(sh(child, "rev-parse", "HEAD")).to eq(head)
  end

  it "rebases only the child's commits onto a force-rebased parent and proves ancestry" do
    live = force_rebase_parent!
    expect(live).not_to eq(@prepared)

    validated = 0
    result = barrier(validator: -> { validated += 1; true }).ensure_fresh!

    expect(result.status).to eq(:rebased)
    expect(result.live_sha).to eq(live)
    expect(validated).to eq(1)
    expect(barrier.descends_from?(live)).to be(true)
    expect(sh(child, "rev-list", "--count", "#{live}..HEAD")).to eq("1")
    expect(child_files).to include("child.txt", "parent.txt")
    expect(workflow.reload.artifact(described_class::PREPARED_ARTIFACT)["sha"]).to eq(live)
  end

  it "does not trust a recorded basis the branch does not descend from (existing child branch, parent moved before setup)" do
    live = force_rebase_parent!
    workflow.set_artifact!(described_class::PREPARED_ARTIFACT, { "ref" => parent_ref, "sha" => live })

    result = barrier.ensure_fresh!

    expect(result.status).to eq(:rebased)
    expect(barrier.descends_from?(live)).to be(true)
    # Only the child's own commit sits on top; superseded parent history was dropped.
    expect(sh(child, "rev-list", "--count", "#{live}..HEAD")).to eq("1")
  end

  it "re-checks after a rebase and rebases again when the parent moves during validation" do
    force_rebase_parent!
    moved = nil
    validator = -> { moved ||= force_rebase_parent!; true }

    result = barrier(validator: validator).ensure_fresh!

    expect(result.rebases).to eq(2)
    expect(result.live_sha).to eq(moved)
    expect(barrier.descends_from?(moved)).to be(true)
  end

  it "retains the completed work and reports awaiting-stable-base when the parent never settles" do
    force_rebase_parent!
    work = sh(child, "rev-parse", "HEAD")
    fetch = -> {
      force_rebase_parent!
      fetch_live.call
    }

    expect { barrier(fetch: fetch, max_rebases: 2).ensure_fresh! }
      .to raise_error(described_class::AwaitingStableBase) { |e|
        expect(e.evidence["observed_parent_heads"].size).to eq(2)
        expect(e.evidence["max_rebases"]).to eq(2)
      }
    expect(child_files).to include("child.txt")
    expect(sh(child, "log", "--format=%s", "-1", "--grep=add child.txt")).to eq("add child.txt")
    expect(work).to be_present
  end

  it "aborts and raises when the child's commits conflict with the moved parent" do
    sh(parent_clone, "checkout", "-q", "parent")
    sh(parent_clone, "reset", "-q", "--hard", "main")
    commit(parent_clone, "child.txt", "conflicting")
    sh(parent_clone, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{parent_ref}")

    expect { barrier.ensure_fresh! }.to raise_error(described_class::RebaseConflict)
    expect(child.join(".git/rebase-merge")).not_to exist
    expect(child.join(".git/rebase-apply")).not_to exist
  end

  it "fails when post-rebase validation fails" do
    force_rebase_parent!

    expect { barrier(validator: -> { false }).ensure_fresh! }.to raise_error(described_class::ValidationFailed)
  end

  it "refuses to proceed when the live parent head cannot be resolved" do
    expect { barrier(fetch: -> { "" }).ensure_fresh! }.to raise_error(described_class::AwaitingStableBase)
  end

  describe ".applicable?" do
    let(:job) { Factories.job(repository: workflow.job.repository, issue_number: 77) }

    it "is false for ordinary main-based Jobs" do
      expect(described_class.applicable?(job, "main")).to be(false)
    end

    it "is true for any Job whose PR base is an open parent Job branch, Epic or not" do
      parent = Factories.job(repository: job.repository, issue_number: 78)
      parent.update!(branch_name: "syrus/issue-78", pr_number: 78)
      job.update!(parent_job: parent)

      expect(job.epic_id).to be_nil
      expect(described_class.applicable?(job, "syrus/issue-78")).to be(true)
      expect(described_class.applicable?(job, "main")).to be(false)
    end
  end

  describe ".record_prepared!" do
    it "keeps the first recorded basis" do
      described_class.record_prepared!(workflow, ref: parent_ref, sha: "f" * 40)

      expect(workflow.reload.artifact(described_class::PREPARED_ARTIFACT)["sha"]).to eq(@prepared)
    end
  end
end
