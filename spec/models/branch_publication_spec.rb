require "rails_helper"
require "tmpdir"

RSpec.describe BranchPublication do
  let(:sha) { "c" * 40 }

  describe ".record_push!" do
    it "records each branch refspec a push names, resolving symbolic sources" do
      resolved = "d" * 40
      described_class.record_push!(
        [ "push", "--force-with-lease=refs/heads/syrus/a:#{sha}", "https://x@github.com/o/r.git", "HEAD:refs/heads/syrus/a", "#{sha}:refs/heads/syrus/b" ],
        chdir: "/tmp", resolve: ->(rev, _dir) { rev == "HEAD" ? resolved : nil }
      )

      expect(described_class.published?(branch_name: "syrus/a", sha: resolved)).to be(true)
      expect(described_class.published?(branch_name: "syrus/b", sha: sha)).to be(true)
    end

    it "ignores deletions, tags, and non-push commands" do
      described_class.record_push!([ "push", "url", ":refs/heads/syrus/gone" ], chdir: "/tmp")
      described_class.record_push!([ "push", "url", "--delete", "refs/heads/syrus/gone" ], chdir: "/tmp")
      described_class.record_push!([ "push", "url", "+#{sha}:refs/tags/wip" ], chdir: "/tmp")
      described_class.record_push!([ "fetch", "url", "#{sha}:refs/heads/syrus/x" ], chdir: "/tmp")

      expect(described_class.count).to eq(0)
    end

    it "is idempotent for a branch head pushed twice" do
      2.times { described_class.record!(branch_name: "syrus/a", sha: sha) }

      expect(described_class.where(branch_name: "syrus/a").count).to eq(1)
    end
  end

  # The one choke point: every step's `git push` goes through GitRunner, so a
  # branch head Syrus published is known whichever step pushed it -- including
  # a parent's stack rebase rewriting a child's branch.
  it "is recorded by GitRunner for a real push" do
    Dir.mktmpdir do |dir|
      remote = File.join(dir, "remote.git")
      work = File.join(dir, "work")
      system("git", "init", "--bare", "-q", remote, exception: true)
      system("git", "init", "-q", work, exception: true)
      system("git", "-C", work, "-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "x", exception: true)
      head = `git -C #{work} rev-parse HEAD`.strip

      GitRunner.new.run("push", remote, "HEAD:refs/heads/syrus/direct-1", chdir: work)

      expect(described_class.published?(branch_name: "syrus/direct-1", sha: head)).to be(true)
    end
  end
end
