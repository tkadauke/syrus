require "rails_helper"

RSpec.describe MergeTrainMemberPrReconciler do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:epic) { Factories.epic(user: user, repository: repository) }
  let(:train) { MergeTrain.create!(epic: epic, repository: repository, base_branch: "master") }
  let(:member_job) do
    Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1,
                          pr_number: 501, branch_name: "syrus/issue-1")
  end
  let(:client) { instance_double(GithubClient) }

  def call(integration_pr: nil, log: nil)
    described_class.call(client: client, repository: repository, train: train, member_job: member_job,
                          integration_pr: integration_pr, log: log)
  end

  it "comments on and closes the member's PR" do
    allow(client).to receive(:add_issue_comment)
    allow(client).to receive(:close_pull_request)

    call

    expect(client).to have_received(:add_issue_comment)
      .with("acme/widgets", 501, a_string_including("Landed via Epic ##{epic.number} merge-train", member_job.slug))
    expect(client).to have_received(:close_pull_request).with("acme/widgets", 501)
  end

  it "mentions the integration PR number in the comment when one is given" do
    allow(client).to receive(:add_issue_comment)
    allow(client).to receive(:close_pull_request)
    integration_pr = OpenStruct.new(number: 999)

    call(integration_pr: integration_pr)

    expect(client).to have_received(:add_issue_comment)
      .with("acme/widgets", 501, a_string_including("integration PR #999"))
  end

  it "does nothing when the member has no PR" do
    allow(client).to receive(:add_issue_comment)
    member_job.update!(pr_number: nil)

    call

    expect(client).not_to have_received(:add_issue_comment)
  end

  it "swallows an Octokit error commenting and still attempts the close" do
    allow(client).to receive(:add_issue_comment).and_raise(Octokit::TooManyRequests.new)
    allow(client).to receive(:close_pull_request)
    logged = []

    expect { call(log: ->(message, kind: nil) { logged << message }) }.not_to raise_error

    expect(client).to have_received(:close_pull_request).with("acme/widgets", 501)
    expect(logged.first).to include("could not comment on PR #501")
  end

  it "swallows an Octokit error closing the PR" do
    allow(client).to receive(:add_issue_comment)
    allow(client).to receive(:close_pull_request).and_raise(Octokit::NotFound.new)
    logged = []

    expect { call(log: ->(message, kind: nil) { logged << message }) }.not_to raise_error

    expect(logged.first).to include("could not close PR #501")
  end
end
