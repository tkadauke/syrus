require "rails_helper"

RSpec.describe JobDetachPlan do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner, default_branch: "main") }
  let(:parent) do
    Factories.job_record(user: owner, repository: repository, branch_name: "syrus/parent", pr_number: 41)
  end
  let(:job) do
    Factories.job_record(
      user: owner, repository: repository, branch_name: "syrus/child", pr_number: 42, parent_job: parent
    )
  end
  let(:child_head) { "c" * 40 }
  let(:parent_head) { "p" * 40 }
  let(:owned_patch_base_sha) { "m" * 40 }
  let(:client) { instance_double(GithubClient) }
  let(:content) { instance_double(RepositoryContent::Reader) }

  it "computes the owned patch from the former parent head rather than the possibly stale PR base" do
    pr = double("pull request", base: double("base", ref: "stale-pr-base"))
    parent_revision = double("parent revision")
    child_revision = double("child revision")
    history = RepositoryContent::CommitHistory.new(
      commits: [ double("commit", sha: child_head, message: "child change") ], merge_base_id: owned_patch_base_sha
    )
    change = double("change", path: "child.rb", status: "modified", patch: "@@")
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:pull_request).and_return(pr)
    allow(client).to receive(:branch_head_sha).with(repository.slug, job.branch_name).and_return(child_head)
    allow(client).to receive(:branch_head_sha).with(repository.slug, parent.branch_name).and_return(parent_head)
    allow(RepositoryContent).to receive(:for).and_return(content)
    allow(content).to receive(:resolve).with(parent_head).and_return(parent_revision)
    allow(content).to receive(:resolve).with(child_head).and_return(child_revision)
    allow(content).to receive(:history).and_return(history)
    allow(content).to receive(:changes).and_return([ change ])

    plan = described_class.for(job, destination_base: "main")

    expect(content).to have_received(:history).with(base: parent_revision, head: child_revision)
    expect(content).to have_received(:changes).with(base: parent_revision, head: child_revision, patch: true)
    expect(plan).to include(
      "live_pr_base" => "stale-pr-base", "former_parent_branch" => parent.branch_name,
      "former_parent_head" => parent_head, "owned_patch_base_sha" => owned_patch_base_sha,
      "current_branch_head" => child_head
    )
  end
end
