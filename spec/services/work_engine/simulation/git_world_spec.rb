require "rails_helper"

RSpec.describe WorkEngine::Simulation::GitWorld do
  subject(:world) { described_class.new(seed: "spec") }

  # base -- main_1                       (main)
  #     \
  #      parent_1 -- child_1             (syrus/parent, syrus/child)
  before do
    world.commit!(label: "base")
    world.commit!(label: "main_1", parents: [ "base" ], paths: [ "lib/main.rb" ])
    world.commit!(label: "parent_1", parents: [ "base" ], paths: [ "lib/parent.rb" ])
    world.commit!(label: "child_1", parents: [ "parent_1" ], paths: [ "lib/child.rb" ])
    world.set_branch!("main", "main_1")
    world.set_branch!("syrus/parent", "parent_1")
    world.set_branch!("syrus/child", "child_1")
  end

  describe "ancestry" do
    it "answers reachability inclusively and resolves branch spellings" do
      expect(world.ancestor?("base", "child_1")).to be(true)
      expect(world.ancestor?("child_1", "child_1")).to be(true)
      expect(world.ancestor?("main_1", "child_1")).to be(false)
      expect(world.resolve("origin/syrus/parent")).to eq(world.sha_for("parent_1"))
      expect(world.resolve("refs/remotes/origin/syrus/parent")).to eq(world.sha_for("parent_1"))
      expect(world.merge_base("child_1", "main_1")).to eq(world.sha_for("base"))
    end

    it "lists a range oldest first" do
      expect(world.range("child_1", exclude: [ "main_1" ]).map(&:label)).to eq(%w[parent_1 child_1])
    end
  end

  describe "rebase" do
    it "drops a commit whose patch the target already holds" do
      copy = world.replay([ world.commit(world.sha_for("parent_1")) ], onto: "main_1").tip
      world.set_branch!("main", copy)

      result = world.rebase(head: "child_1", onto: "main")

      expect(result).not_to be_conflicted
      expect(result.dropped.map(&:label)).to eq(%w[parent_1])
      expect(result.applied.map(&:label)).to eq(%w[child_1])
      expect(world.ancestor?("main", result.tip)).to be(true)
    end

    it "is deterministic: the same replay yields the same commit" do
      first = world.rebase(head: "child_1", onto: "main").tip
      second = world.rebase(head: "child_1", onto: "main").tip

      expect(first).to eq(second)
    end

    it "conflicts when the target side rewrote the same paths with a different patch" do
      rewritten = world.rewrite_branch!("syrus/parent", onto: "main", patch_equivalent: false)

      plain = world.rebase(head: "child_1", onto: rewritten)
      expect(plain).to be_conflicted
      expect(plain.conflict.label).to eq("parent_1")
      expect(plain.conflicts).to eq(%w[lib/parent.rb])

      own_commits_only = world.rebase(head: "child_1", onto: rewritten, upstream: "parent_1")
      expect(own_commits_only).not_to be_conflicted
      expect(own_commits_only.applied.map(&:label)).to eq(%w[child_1])
    end

    it "keeps patches through a patch-equivalent rewrite, so a plain rebase of the child is clean" do
      rewritten = world.rewrite_branch!("syrus/parent", onto: "main", patch_equivalent: true)

      result = world.rebase(head: "child_1", onto: rewritten)

      expect(result).not_to be_conflicted
      expect(result.dropped.map(&:label)).to eq(%w[parent_1])
    end

    it "lands a conflicting commit when resolving, as an agent rebase does" do
      rewritten = world.rewrite_branch!("syrus/parent", onto: "main", patch_equivalent: false)

      result = world.rebase(head: "child_1", onto: rewritten, resolve: true)

      expect(result).not_to be_conflicted
      expect(world.ancestor?(rewritten, result.tip)).to be(true)
    end
  end

  describe "pull request mergeability" do
    before do
      world.set_branch!("syrus/feature", world.commit!(label: "feature_1", parents: [ "main_1" ], paths: [ "lib/feature.rb" ]).id)
      world.open_pull_request!(number: 7, head_branch: "syrus/feature", base_branch: "main")
    end

    let(:pr) { world.pull_request(7) }

    it "is clean while the head contains the base tip and checks pass" do
      expect(world.mergeability(pr)).to eq([ true, "clean" ])
    end

    it "is blocked when checks fail" do
      pr.checks = "failing"
      expect(world.mergeability(pr)).to eq([ true, "blocked" ])
    end

    it "is behind once the base moves without touching the PR's paths" do
      world.advance_branch!("main", paths: [ "lib/other.rb" ])
      expect(world.mergeability(pr)).to eq([ true, "behind" ])
    end

    it "is dirty once the base gains an overlapping change, and clean after a resolving rebase is pushed" do
      world.make_pull_request_dirty!(7)
      expect(world.mergeability(pr)).to eq([ false, "dirty" ])

      world.set_branch!("syrus/feature", world.rebase(head: "syrus/feature", onto: "main", resolve: true).tip)
      expect(world.mergeability(pr)).to eq([ true, "clean" ])
    end

    it "answers unknown for the requested number of reads" do
      pr.unknown_reads = 1
      expect(world.mergeability(pr)).to eq([ nil, "unknown" ])
      expect(world.mergeability(pr)).to eq([ true, "clean" ])
    end

    it "keeps base.sha at the last sync until the head is pushed" do
      synced = pr.synced_base_sha
      world.advance_branch!("main", paths: [ "lib/other.rb" ])
      expect(pr.synced_base_sha).to eq(synced)

      world.pushed!("syrus/feature")
      expect(pr.synced_base_sha).to eq(world.resolve("main"))
    end
  end

  describe "merging" do
    before do
      world.open_pull_request!(number: 1, head_branch: "syrus/parent", base_branch: "main")
      world.open_pull_request!(number: 2, head_branch: "syrus/child", base_branch: "syrus/parent")
    end

    it "rebase-merges, deletes the head branch, and retargets PRs based on it" do
      merged = world.merge_pull_request!(1)

      expect(world.resolve("main")).to eq(merged)
      expect(world.branch?("syrus/parent")).to be(false)
      expect(world.pull_request(1)).to have_attributes(state: "closed", merged: true)
      expect(world.pull_request(2).base_branch).to eq("main")
      expect(world.rebase(head: "syrus/child", onto: "main").applied.map(&:label)).to eq(%w[child_1])
    end

    it "keeps the head branch without delete-on-merge" do
      world.delete_branch_on_merge = false
      world.merge_pull_request!(1)

      expect(world.branch?("syrus/parent")).to be(true)
      expect(world.pull_request(2).base_branch).to eq("syrus/parent")
    end

    it "refuses to merge a conflicting PR" do
      world.make_pull_request_dirty!(1)
      expect { world.merge_pull_request!(1) }.to raise_error(described_class::MergeConflict)
    end
  end

  describe "SimulatedGit" do
    let(:checkout) { world.checkout("child", branch: "syrus/child") }
    let(:git) { WorkEngine::Simulation::GitWorld::SimulatedGit.new(world, checkout) }

    it "answers ancestry, counts, and a conflicted rebase that stays in progress until aborted" do
      rewritten = world.rewrite_branch!("syrus/parent", onto: "main", patch_equivalent: false)

      expect { git.run("merge-base", "--is-ancestor", rewritten, "HEAD") }.to raise_error(GitRunner::GitError)
      expect(git.run("rev-list", "--count", "#{world.sha_for('parent_1')}..HEAD").strip).to eq("1")
      expect { git.run("cat-file", "-e", "#{world.sha_for('parent_1')}^{commit}") }.not_to raise_error

      expect { git.run("rebase", rewritten) }.to raise_error(GitRunner::GitError, /CONFLICT/)
      expect(git.run("diff", "--name-only", "--diff-filter=U")).to eq("lib/parent.rb\n")
      git.run("rebase", "--abort")
      expect(checkout.head).to eq(world.sha_for("child_1"))

      git.run("rebase", "--onto", rewritten, world.sha_for("parent_1"))
      expect(world.ancestor?(rewritten, checkout.head)).to be(true)
      expect(git.run("rev-parse", "HEAD").strip).to eq(checkout.head)
    end

    it "refuses commands it does not model" do
      expect { git.run("gc") }.to raise_error(NotImplementedError, /git gc/)
    end
  end
end
