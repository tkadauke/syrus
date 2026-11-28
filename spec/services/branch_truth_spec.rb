require "rails_helper"
require "tmpdir"

RSpec.describe BranchTruth do
  describe ".outcome_for" do
    it "states the decision rule as a table" do
      table = {
        [ :absent, nil, nil ] => :publish,
        [ :identical, nil, nil ] => :up_to_date,
        [ :fast_forward, nil, nil ] => :publish,
        [ :rewrite, nil, nil ] => :publish,
        [ :remote_ahead, nil, nil ] => :adopt_remote,
        [ :equivalent, nil, nil ] => :adopt_remote,
        [ :equivalent, true, true ] => :adopt_remote,
        [ :equivalent, false, true ] => :adopt_remote,
        [ :equivalent, true, false ] => :publish,
        [ :remote_contains_local, nil, nil ] => :adopt_remote,
        [ :remote_contains_local, true, true ] => :adopt_remote,
        [ :remote_contains_local, true, false ] => :ambiguous,
        [ :local_contains_remote, nil, nil ] => :rebase_onto_remote,
        [ :local_contains_remote, false, true ] => :rebase_onto_remote,
        [ :local_contains_remote, true, true ] => :publish,
        [ :local_contains_remote, true, false ] => :publish,
        [ :diverged, true, false ] => :ambiguous,
        [ :unknown, nil, nil ] => :ambiguous
      }

      table.each do |(relation, local_fresh, remote_fresh), expected|
        expect(described_class.outcome_for(relation, local_fresh: local_fresh, remote_fresh: remote_fresh))
          .to eq(expected), "#{relation} local_fresh=#{local_fresh.inspect} remote_fresh=#{remote_fresh.inspect}"
      end
    end
  end

  describe ".classify on real git topologies", :ci_only do
    let(:git) { GitRunner.new }
    let(:tmp) { Pathname.new(Dir.mktmpdir("branch-truth")) }
    let(:repo) { tmp.join("repo") }

    after { FileUtils.rm_rf(tmp) }

    def sh(*args) = git.run(*args, chdir: repo.to_s).strip

    def commit(file, content = file)
      FileUtils.mkdir_p(repo.join(file).dirname)
      File.write(repo.join(file), content)
      sh("add", file)
      sh("commit", "-q", "-m", "add #{file}")
      sh("rev-parse", "HEAD")
    end

    def classify(remote:, base: nil, rewritten_from: [], local: "HEAD")
      described_class.classify(git: git, chdir: repo, local: local, remote: remote, base: base, rewritten_from: rewritten_from)
    end

    before do
      FileUtils.mkdir_p(repo)
      git.run("init", "-q", "-b", "main", repo.to_s)
      sh("config", "user.name", "t")
      sh("config", "user.email", "t@example.com")
      @root = commit("base.txt")
    end

    it "publishes a branch the remote does not have yet" do
      sh("checkout", "-q", "-b", "work")
      commit("work.txt")

      truth = classify(remote: nil, base: "main")
      expect([ truth.relation, truth.outcome, truth.lease_sha ]).to eq([ :absent, :publish, "" ])
    end

    it "has nothing to publish when the heads are identical" do
      expect(classify(remote: @root)).to have_attributes(relation: :identical, outcome: :up_to_date)
    end

    it "publishes a fast-forward" do
      commit("more.txt")
      expect(classify(remote: @root)).to have_attributes(relation: :fast_forward, outcome: :publish, rewrites_remote?: false)
    end

    it "adopts a remote that someone else advanced on top of the local head" do
      local = commit("work.txt")
      remote = commit("reviewer-fix.txt")
      sh("reset", "-q", "--hard", local)

      expect(classify(remote: remote)).to have_attributes(relation: :remote_ahead, outcome: :adopt_remote)
    end

    it "publishes over the exact head local was deliberately rewritten from" do
      sh("checkout", "-q", "-b", "work")
      pre = commit("work.txt", "one")
      sh("reset", "-q", "--hard", @root)
      commit("work.txt", "conflict-resolved differently")

      truth = classify(remote: pre, rewritten_from: [ pre ])
      expect(truth).to have_attributes(relation: :rewrite, outcome: :publish, lease_sha: pre, rewrites_remote?: true)
    end

    context "when an Epic-wide stack rebase rewrote the remote branch" do
      # main -- P (parent) -- C (child work).  Then main advances, the parent
      # is rebased onto it (P'), and the child's PR branch is rebased onto P'
      # (C'). The workflow still holds the pre-rebase C locally.
      before do
        sh("checkout", "-q", "-b", "parent")
        commit("parent.txt")
        sh("checkout", "-q", "-b", "child")
        @old_child = commit("child.txt")

        sh("checkout", "-q", "main")
        commit("main-moved.txt")
        sh("checkout", "-q", "parent")
        sh("rebase", "-q", "main")
        @new_parent = sh("rev-parse", "HEAD")
        sh("checkout", "-q", "-b", "child-rebased")
        sh("cherry-pick", @old_child)
        @rebased_child = sh("rev-parse", "HEAD")
      end

      it "adopts the remote when it holds the same patches on the fresh base" do
        sh("checkout", "-q", @old_child)

        truth = classify(remote: @rebased_child, base: @new_parent)
        expect(truth).to have_attributes(relation: :equivalent, outcome: :adopt_remote, local_fresh: false, remote_fresh: true)
        expect(truth.to_h).to include("local_only_commits" => 1, "remote_only_commits" => 1, "local_unmatched_commits" => 0)
      end

      it "asks to replay the extra local commit onto the remote rather than overwrite the rebase" do
        sh("checkout", "-q", "-b", "local-output", @old_child)
        commit("review-fix.txt")

        expect(classify(remote: @rebased_child, base: @new_parent))
          .to have_attributes(relation: :local_contains_remote, outcome: :rebase_onto_remote)
      end

      it "adopts the remote when the rebase also brought extra remote work" do
        sh("checkout", "-q", "child-rebased")
        remote = commit("someone-else.txt")
        sh("checkout", "-q", @old_child)

        expect(classify(remote: remote, base: @new_parent))
          .to have_attributes(relation: :remote_contains_local, outcome: :adopt_remote)
      end

      it "publishes the local copy when local is the one on the fresh base" do
        sh("checkout", "-q", "child-rebased")

        truth = classify(remote: @old_child, base: @new_parent)
        expect(truth).to have_attributes(relation: :equivalent, outcome: :publish, local_fresh: true, remote_fresh: false, rewrites_remote?: true)
      end

      it "still adopts without a base, because the remote holds every local patch" do
        sh("checkout", "-q", @old_child)

        expect(classify(remote: @rebased_child)).to have_attributes(relation: :remote_contains_local, outcome: :adopt_remote)
      end
    end

    it "assumes the remote is at least as fresh without a base" do
      sh("checkout", "-q", "-b", "work")
      published = commit("work.txt")
      sh("reset", "-q", "--hard", @root)
      sh("-c", "user.name=someone-else", "cherry-pick", published)
      rewritten = sh("rev-parse", "HEAD")
      sh("reset", "-q", "--hard", published)
      commit("review-fix.txt")

      expect(classify(remote: rewritten))
        .to have_attributes(relation: :local_contains_remote, outcome: :rebase_onto_remote)
    end

    it "names the retry recovery when the two sides hold different work" do
      sh("checkout", "-q", "-b", "remote-side")
      remote = commit("feature.txt", "their implementation")
      sh("checkout", "-q", "-b", "local-side", @root)
      commit("feature.txt", "our implementation")

      truth = classify(remote: remote, base: "main")
      expect(truth).to have_attributes(relation: :diverged, outcome: :ambiguous)
      expect(truth.to_h).to include("recommended_recovery" => "retry_from_current_pr_branch", "remote_unmatched_commits" => 1)
    end

    it "does not treat a remote-only merge commit as preserved content" do
      sh("checkout", "-q", "-b", "side")
      side = commit("side.txt")
      sh("checkout", "-q", "-b", "integration", @root)
      local = commit("member.txt")
      sh("merge", "-q", "--no-ff", "-m", "merge side", side)
      remote = sh("rev-parse", "HEAD")
      sh("checkout", "-q", "-b", "rebuilt", @root)
      sh("cherry-pick", local)
      commit("other.txt")

      truth = classify(remote: remote, base: "main")
      expect(truth.outcome).to eq(:ambiguous)
    end

    it "treats identical trees with different histories as equivalent" do
      sh("checkout", "-q", "-b", "a")
      commit("x.txt", "1")
      remote = commit("y.txt", "2")
      sh("checkout", "-q", "-b", "b", @root)
      File.write(repo.join("x.txt"), "1")
      File.write(repo.join("y.txt"), "2")
      sh("add", ".")
      sh("commit", "-q", "-m", "squashed")

      expect(classify(remote: remote, base: "main")).to have_attributes(relation: :equivalent, outcome: :adopt_remote)
    end

    it "fails closed when the remote head is not in the repository" do
      truth = classify(remote: "f" * 40, base: "main")
      expect(truth).to have_attributes(relation: :unknown, outcome: :ambiguous)
    end
  end
end
