require "rails_helper"

RSpec.describe App::TargetGraphCheckout do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:git) { instance_double(GitRunner) }
  let(:clone_path) { Pathname.new("/tmp/target-graph-checkout.git") }
  let(:clone) { instance_double(RepositoryBareClone, sync!: true, path: clone_path) }

  it "fetches explicit remote refs before exporting them" do
    checkout = described_class.new(repository: repository, user: user, git: git)
    ref = "refs/syrus/checkpoints/runs/123"
    url = "https://example.test/acme/widgets.git"

    allow(RepositoryBareClone).to receive(:new).with(repository, git: git).and_return(clone)
    allow(GithubAuthenticatedGit).to receive(:run)
      .with(repository: repository, user: user, git: git, operation_type: "git_target_graph_fetch_ref")
      .and_yield(url)
    expect(git).to receive(:run)
      .with(
        "fetch",
        url,
        "+#{ref}:#{ref}",
        chdir: clone_path.to_s,
        env: { "GIT_TERMINAL_PROMPT" => "0" }
      )

    allow(checkout).to receive(:export_ref!) do |_source, exported_ref, destination|
      expect(exported_ref).to eq(ref)
      File.write(File.join(destination, ".syrus.yml"), "prepare: []\n")
    end

    checkout.with_ref(ref) do |path|
      expect(path.join(".syrus.yml")).to exist
    end
  end
end
