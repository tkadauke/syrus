require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RepositoryBareCloneRemoteScrubber, :ci_only do
  let(:syrus_data_root) { Pathname.new(Dir.mktmpdir("syrus-data")) }
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }

  before do
    ENV["SYRUS_DATA_ROOT"] = syrus_data_root.to_s
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(syrus_data_root)
  end

  def git(*args, chdir: nil)
    command = [ "git" ]
    command += [ "-C", chdir.to_s ] if chdir
    command += args
    output = `#{command.join(' ')} 2>&1`
    raise "git #{args.join(' ')} failed: #{output}" unless $?.success?

    output.strip
  end

  def init_bare_clone(path, remote_url:)
    FileUtils.mkdir_p(path.dirname)
    git("init", "--bare", path.to_s)
    git("--git-dir=#{path}", "remote", "add", "origin", remote_url)
  end

  it "rewrites repository-backed bare clone origin URLs to anonymous remotes" do
    clone_path = RepositoryBareClone.path_for(repository)
    init_bare_clone(
      clone_path,
      remote_url: "https://x-access-token:#{user.github_token}@github.com/#{repository.owner}/#{repository.name}.git"
    )

    scrubber = described_class.new

    expect(scrubber.credentialed_remote_count).to eq(1)

    result = scrubber.scrub_batch(limit: 10)

    remote_url = git("--git-dir=#{clone_path}", "config", "--get", "remote.origin.url")
    expect(result).to have_attributes(processed: 1, scrubbed: 1, removed: 0, failed: 0, done: true)
    expect(remote_url).to eq(repository.remote_url)
    expect(remote_url).not_to include("x-access-token")
    expect(remote_url).not_to include(user.github_token)
    expect(scrubber.credentialed_remote_count).to eq(0)
  end

  it "removes credentialed origin remotes from orphaned bare clone directories" do
    clone_path = WorkflowWorkspace.data_root.join("clones", "999999.git")
    init_bare_clone(
      clone_path,
      remote_url: "https://x-access-token:#{user.github_token}@github.com/acme/orphan.git"
    )

    result = described_class.new.scrub_batch(limit: 10)

    remotes = git("--git-dir=#{clone_path}", "remote")
    expect(result).to have_attributes(processed: 1, scrubbed: 0, removed: 1, failed: 0, done: true)
    expect(remotes.lines.map(&:strip)).not_to include("origin")
  end

  it "ignores anonymous bare clone origin URLs" do
    clone_path = RepositoryBareClone.path_for(repository)
    init_bare_clone(clone_path, remote_url: repository.remote_url)

    scrubber = described_class.new

    expect(scrubber.credentialed_remote_count).to eq(0)
    expect(scrubber.scrub_batch(limit: 10)).to have_attributes(processed: 0, scrubbed: 0, removed: 0, failed: 0, done: true)
  end
end
