require "rails_helper"

RSpec.describe StackChildPullRequestRetargeter do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:parent) { Factories.job(user: user, repository: repository, pr_number: 10, branch_name: "syrus/parent") }
  let(:client) { instance_double(GithubClient) }

  def child(pr_number:, **attrs)
    Factories.job(user: user, repository: repository, pr_number: pr_number, branch_name: "syrus/child-#{pr_number}", **attrs)
      .tap { |job| job.update_columns(parent_job_id: parent.id) }
  end

  it "retargets open child PRs and skips excluded, closed, and PR-less children" do
    open_child = child(pr_number: 11)
    skipped = child(pr_number: 12)
    closed = child(pr_number: 13)
    closed.update_columns(state: "closed")
    child(pr_number: nil)
    allow(client).to receive(:update_pull_request_base)

    retargeted = described_class.call(client: client, parent: parent, base: "main", skip_job_ids: [ skipped.id ])

    expect(retargeted).to eq([ open_child ])
    expect(client).to have_received(:update_pull_request_base).once.with("acme/widgets", 11, base: "main")
  end

  it "keeps going when GitHub refuses a retarget" do
    child(pr_number: 11)
    second = child(pr_number: 12)
    allow(client).to receive(:update_pull_request_base).with("acme/widgets", 11, base: "main")
      .and_raise(Octokit::UnprocessableEntity)
    allow(client).to receive(:update_pull_request_base).with("acme/widgets", 12, base: "main")

    expect(described_class.call(client: client, parent: parent, base: "main")).to eq([ second ])
  end
end
