require "rails_helper"

RSpec.describe Coworkers::RemoteWorkspace do
  let(:user) { Factories.user }

  around do |example|
    Dir.mktmpdir("coworker-remote-spec-") do |root|
      @root = root
      @bare_remote = File.join(root, "coworker-homes.git")
      GitRunner.new.run("init", "--bare", @bare_remote)
      example.run
    end
  end

  def remote_workspace
    described_class.new(owner: "acme", name: "coworker-homes", user: user).tap do |remote|
      allow(remote).to receive(:authenticated_url).and_return(@bare_remote)
    end
  end

  def seed(remote, branch: "coworkers/maya")
    remote.seed!(
      branch: branch,
      files: { "SOUL.md" => "role: tester\n" },
      identity: Coworkers::GitIdentity.new(name: "Maya", handle: "maya")
    )
  end

  it "deletes a coworker branch when called outside a Git repository" do
    remote = remote_workspace
    seed(remote)
    caller_directory = File.join(@root, "not-a-repository")
    FileUtils.mkdir_p(caller_directory)

    Dir.chdir(caller_directory) { remote.delete!("coworkers/maya") }

    expect(remote.branch_exists?("coworkers/maya")).to be(false)
  end

  it "does not delete refs outside the coworker namespace" do
    remote = remote_workspace

    expect { remote.delete!("main") }
      .to raise_error(ArgumentError, "coworker pushes may only target refs under coworkers/")
  end
end
