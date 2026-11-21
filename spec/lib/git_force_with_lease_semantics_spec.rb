require "rails_helper"
require "open3"

# DOC-44 Phase 3, Git boundary: the behaviour of real git that
# formal/SyrusModel/ForcePushLease.lean assumes. Every Syrus force push names
# the remote it pushes to by URL and leases in one of three forms:
#
# * `--force-with-lease=refs/heads/<b>:<sha>` (Steps::ForcePush, AutoRebase,
#   Steps::StackForcePush, Steps::MergeTrainLand, ...): succeeds only while the
#   remote branch is exactly <sha>;
# * `--force-with-lease=refs/heads/<b>:` (empty expectation): succeeds only
#   while the remote branch does not exist;
# * bare `--force-with-lease` against a URL (StackForcePush's fallback): there
#   is no remote-tracking ref to compare with, so git refuses once the branch
#   exists ("stale info") -- fail closed, never an overwrite.
#
# Each example runs real git against a local bare repository.
RSpec.describe "git force-with-lease semantics" do
  around do |example|
    Dir.mktmpdir("syrus-lease") do |dir|
      @root = Pathname.new(dir)
      example.run
    end
  end

  def git(*args, chdir:)
    out, status = Open3.capture2e("git", "-c", "user.name=Syrus", "-c", "user.email=syrus@example.invalid",
                                  "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false", *args, chdir: chdir.to_s)
    [ out, status.success? ]
  end

  def git!(*args, chdir:)
    out, ok = git(*args, chdir: chdir)
    raise "git #{args.join(' ')} failed: #{out}" unless ok

    out.strip
  end

  def commit!(clone, message)
    File.write(clone.join("file.txt"), "#{message}\n")
    git!("add", "file.txt", chdir: clone)
    git!("commit", "-m", message, chdir: clone)
    git!("rev-parse", "HEAD", chdir: clone)
  end

  let(:remote) { @root.join("remote.git").tap { |path| git!("init", "--bare", path.to_s, chdir: @root) } }
  let(:url) { "file://#{remote}" }

  def clone!(name)
    @root.join(name).tap do |path|
      git!("clone", url, path.to_s, chdir: @root)
    end
  end

  # Syrus observes the remote at `observed`, another writer then pushes on top.
  def diverged_remote
    syrus = clone!("syrus")
    observed = commit!(syrus, "base")
    git!("push", url, "HEAD:refs/heads/feature", chdir: syrus)

    other = clone!("other")
    git!("fetch", url, "feature", chdir: other)
    git!("checkout", "-b", "feature", "FETCH_HEAD", chdir: other)
    unobserved = commit!(other, "someone else's work")
    git!("push", url, "HEAD:refs/heads/feature", chdir: other)

    git!("commit", "--amend", "-m", "syrus rewrite", chdir: syrus)
    [ syrus, observed, unobserved ]
  end

  def remote_sha(branch)
    git!("rev-parse", "refs/heads/#{branch}", chdir: remote)
  end

  it "rejects an explicit lease once the remote moved past the observed SHA" do
    syrus, observed, unobserved = diverged_remote

    _out, ok = git("push", "--force-with-lease=refs/heads/feature:#{observed}", url, "HEAD:refs/heads/feature", chdir: syrus)

    expect(ok).to be(false)
    expect(remote_sha("feature")).to eq(unobserved)
  end

  it "accepts an explicit lease while the remote is still the observed SHA" do
    syrus = clone!("syrus")
    observed = commit!(syrus, "base")
    git!("push", url, "HEAD:refs/heads/feature", chdir: syrus)
    git!("commit", "--amend", "-m", "syrus rewrite", chdir: syrus)
    rewritten = git!("rev-parse", "HEAD", chdir: syrus)

    _out, ok = git("push", "--force-with-lease=refs/heads/feature:#{observed}", url, "HEAD:refs/heads/feature", chdir: syrus)

    expect(ok).to be(true)
    expect(remote_sha("feature")).to eq(rewritten)
  end

  it "rejects an empty-expectation lease when the branch exists" do
    syrus, _observed, unobserved = diverged_remote

    _out, ok = git("push", "--force-with-lease=refs/heads/feature:", url, "HEAD:refs/heads/feature", chdir: syrus)

    expect(ok).to be(false)
    expect(remote_sha("feature")).to eq(unobserved)
  end

  it "refuses a bare lease against a URL once the branch exists, instead of overwriting" do
    syrus, _observed, unobserved = diverged_remote

    out, ok = git("push", "--force-with-lease", url, "HEAD:refs/heads/feature", chdir: syrus)

    expect(ok).to be(false)
    expect(out).to match(/stale info|rejected/)
    expect(remote_sha("feature")).to eq(unobserved)
  end
end
