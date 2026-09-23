require "rails_helper"
require "ostruct"

RSpec.describe LandingQueueRecheck do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:head_sha) { "b" * 40 }
  let(:base_sha) { "a" * 40 }
  let(:job) do
    j = Factories.job(user: user, repository: repository, pr_number: 7, branch_name: "syrus/issue-42-1")
    j.update_columns(state: "approved", approved_at: Time.current, approved_via: "operator")
    j
  end
  let(:client) { instance_double(GithubClient) }

  def pr
    repo = OpenStruct.new(full_name: "acme/widgets")
    OpenStruct.new(
      merged: false,
      state: "open",
      mergeable: true,
      mergeable_state: "clean",
      head: OpenStruct.new(repo: repo, sha: head_sha),
      base: OpenStruct.new(repo: repo, ref: "main", sha: base_sha)
    )
  end

  before do
    job # force creation (reads .syrus.yml through the default fake provider) before any test overrides the provider chain
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:pull_request).and_return(pr)
    allow(client).to receive(:check_runs_detail_for).and_return(
      pending?: false, any_failed?: false, all_passed?: true, failed_checks: [], completed_checks: []
    )
    allow(LandingQueueProcessor).to receive(:refresh_snapshot!).and_return([])
    allow(LandingQueueProcessorJob).to receive(:perform_later)
  end

  describe "commits_behind refresh" do
    it "prefers a provider's numeric divergence over the bare clone" do
      stub_repository_divergence_provider(behind: 9)
      expect(RepositoryBareClone).not_to receive(:new)

      result = described_class.call(job)

      expect(job.reload.commits_behind_base).to eq(9)
      expect(result.commits_behind_refreshed).to be(true)
    end

    it "falls back to the bare clone when no provider supports divergence" do
      # FakeRepositoryContentProvider (the spec-wide default) does not
      # implement #divergence, so the chain raises Unsupported.
      fake_clone = instance_double(RepositoryBareClone)
      allow(RepositoryBareClone).to receive(:new).and_return(fake_clone)
      allow(fake_clone).to receive(:sync!)
      allow(fake_clone).to receive(:commits_behind).with(head_sha: head_sha, base_sha: base_sha).and_return(6)

      result = described_class.call(job)

      expect(job.reload.commits_behind_base).to eq(6)
      expect(result.commits_behind_refreshed).to be(true)
    end

    it "records the refresh as failed without raising when both the provider and the bare clone fail" do
      stub_repository_divergence_provider(behind: 0, error: RepositoryContent::Unavailable.new("outage"))
      allow(RepositoryBareClone).to receive(:new).and_raise(GitRunner::GitError.new([ "fetch" ], 1, "boom"))

      result = described_class.call(job)

      expect(result.commits_behind_refreshed).to be(false)
      expect(result.warnings).to include(a_string_matching(/commits-behind refresh failed/))
    end
  end
end
