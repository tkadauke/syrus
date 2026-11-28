require "rails_helper"
require "tmpdir"

RSpec.describe StackBaseFreshness, :ci_only do
  # ProcessRunner's test environment may not include the active Ruby's bin dir,
  # while the repository's real merge driver intentionally uses env ruby.
  let(:git) { GitRunner.new(env: { "PATH" => "#{RbConfig::CONFIG.fetch('bindir')}:#{ENV.fetch('PATH')}" }) }
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
    FileUtils.mkdir_p(parent_clone.join("bin"))
    FileUtils.mkdir_p(parent_clone.join("db"))
    FileUtils.cp(Rails.root.join("bin/merge-ruby-schema"), parent_clone.join("bin/merge-ruby-schema"))
    FileUtils.chmod(0o755, parent_clone.join("bin/merge-ruby-schema"))
    File.write(parent_clone.join(".gitattributes"), "db/schema.rb merge=ruby_schema\n")
    File.write(parent_clone.join("db/schema.rb"), schema(version: "2026_01_01_000001"))
    sh(parent_clone, "add", ".gitattributes", "bin/merge-ruby-schema", "db/schema.rb")
    sh(parent_clone, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "add schema driver")
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

  def schema(version:, body: "create_table \"widgets\", force: :cascade do |t|\n  t.string \"name\"\nend")
    <<~RUBY
      ActiveRecord::Schema[8.1].define(version: #{version}) do
        #{body}
      end
    RUBY
  end

  def replace_schema(dir, version:, body: nil, message:)
    File.write(dir.join("db/schema.rb"), schema(version: version, **({ body: body }.compact)))
    sh(dir, "add", "db/schema.rb")
    sh(dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", message)
  end

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

  # Regression (a stacked Epic child after an Epic-wide stack rebase): the
  # parent was rewritten with changes to its own files, and the child's retry
  # inherited a prepared SHA naming the *new* parent head while its
  # workspace still held work built on the old one. The plain-rebase
  # fallback replayed the parent's superseded commit too and conflicted
  # add/add on every retry; the old head was on record in an earlier
  # workflow's conflict evidence.
  it "replays from an earlier recorded base when the inherited one is not an ancestor" do
    sh(parent_clone, "checkout", "-q", "main")
    commit(parent_clone, "main-moved.txt")
    sh(parent_clone, "push", "-q", "origin", "main")
    sh(parent_clone, "checkout", "-q", "-B", "parent", "main")
    commit(parent_clone, "parent.txt", "parent, revised during the stack rebase")
    sh(parent_clone, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{parent_ref}")
    live = sh(parent_clone, "rev-parse", "HEAD")

    Workflow.create!(job: workflow.job, trigger_kind: "retry").set_artifact!(
      "stack_base_rebase_conflict", { "prepared_sha" => @prepared, "live_sha" => live }
    )
    workflow.set_artifact!(described_class::PREPARED_ARTIFACT, { "ref" => parent_ref, "sha" => live })

    result = barrier.ensure_fresh!

    expect(result.status).to eq(:rebased)
    expect(barrier.descends_from?(live)).to be(true)
    expect(sh(child, "rev-list", "--count", "#{live}..HEAD")).to eq("1")
    expect(File.read(child.join("parent.txt"))).to eq("parent, revised during the stack rebase")
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

  # Regression: a stacked child that had merged main (a grader repair does
  # this) carried main's commits in prepared..HEAD. Once the parent was rebased
  # onto that same main, `rebase --onto live prepared` replayed those main
  # commits one by one on top of a base that already contained them, and the
  # replay conflicted -- 123 commits for a child with a handful of its own.
  it "replays only the child's own commits when the child merged main the parent has since absorbed" do
    sh(parent_clone, "checkout", "-q", "main")
    commit(parent_clone, "shared.txt", "one\n")
    commit(parent_clone, "shared.txt", "two\n")
    sh(parent_clone, "push", "-q", "origin", "main")
    sh(child, "fetch", "-q", "origin", "main")
    sh(child, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-edit", "origin/main")
    commit(child, "child-after-merge.txt")
    sh(parent_clone, "checkout", "-q", "parent")
    sh(parent_clone, "-c", "user.name=t", "-c", "user.email=t@example.com", "rebase", "-q", "main")
    sh(parent_clone, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{parent_ref}")
    live = fetch_live.call

    # Prove the fixture hits the bug with the plain --onto replay.
    expect { sh(child, "rebase", "--onto", live, @prepared) }.to raise_error(GitRunner::GitError)
    sh(child, "rebase", "--abort")

    result = barrier.ensure_fresh!

    expect(result.status).to eq(:rebased)
    expect(barrier.descends_from?(live)).to be(true)
    expect(sh(child, "log", "--format=%s", "#{live}..HEAD").split("\n"))
      .to eq([ "add child-after-merge.txt", "add child.txt" ])
    expect(child.join("shared.txt").read).to eq("two\n")
    expect(child_files).to include("child.txt", "child-after-merge.txt", "parent.txt")
  end

  it "restores the completed work when replaying the child's own commits conflicts" do
    sh(parent_clone, "checkout", "-q", "main")
    commit(parent_clone, "shared.txt", "one\n")
    sh(parent_clone, "push", "-q", "origin", "main")
    sh(child, "fetch", "-q", "origin", "main")
    sh(child, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-edit", "origin/main")
    work = sh(child, "rev-parse", "HEAD")
    sh(parent_clone, "checkout", "-q", "parent")
    sh(parent_clone, "-c", "user.name=t", "-c", "user.email=t@example.com", "rebase", "-q", "main")
    commit(parent_clone, "child.txt", "conflicting")
    sh(parent_clone, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{parent_ref}")

    expect { barrier.ensure_fresh! }.to raise_error(described_class::RebaseConflict) { |error|
      expect(error.evidence["conflicted_files"]).to include(hash_including("path" => "child.txt"))
    }
    expect(sh(child, "rev-parse", "HEAD")).to eq(work)
    expect(child.join(".git/CHERRY_PICK_HEAD")).not_to exist
    expect(child.join(".git/sequencer")).not_to exist
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

  it "registers the repository schema driver so version-only migration updates rebase cleanly" do
    replace_schema(child, version: "2026_01_02_000001", message: "child migration")
    sh(parent_clone, "checkout", "-q", "parent")
    replace_schema(parent_clone, version: "2026_01_03_000001", message: "parent migration")
    sh(parent_clone, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{parent_ref}")
    live = fetch_live.call

    # Prove the fixture really conflicts when the local driver is absent.
    expect { sh(child, "rebase", "--onto", live, @prepared) }.to raise_error(GitRunner::GitError)
    sh(child, "rebase", "--abort")

    result = barrier.ensure_fresh!

    expect(result.status).to eq(:rebased)
    expect(child.join("db/schema.rb").read).to include("2026_01_03_000001")
    expect(sh(child, "config", "--get", "merge.ruby_schema.driver")).to include("bin/merge-ruby-schema")
  end

  it "reports a real schema body conflict and the registered driver evidence" do
    replace_schema(child, version: "2026_01_02_000001", body: "create_table \"widgets\" do |t|\n  t.string \"child_name\"\nend", message: "child schema edit")
    sh(parent_clone, "checkout", "-q", "parent")
    replace_schema(parent_clone, version: "2026_01_03_000001", body: "create_table \"widgets\" do |t|\n  t.string \"parent_name\"\nend", message: "parent schema edit")
    sh(parent_clone, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{parent_ref}")

    expect { barrier.ensure_fresh! }.to raise_error(described_class::RebaseConflict) { |error|
      expect(error.evidence["conflicted_files"]).to include(
        "path" => "db/schema.rb",
        "merge_driver" => "ruby_schema",
        "merge_driver_registered" => true
      )
      expect(error.message).to include("rebasing completed work")
    }
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
