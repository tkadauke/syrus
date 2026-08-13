require "rails_helper"

RSpec.describe Job::ApprovalUnapprover do
  let(:user) { Factories.user(email_address: "operator@example.com") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(repository: repository, issue_number: 42) }
  let(:client) { instance_double(GithubClient) }

  before do
    job.update!(pr_number: 123, state: "implemented")
    job.approve!(via: "operator") if job.may_approve?
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
  end

  it "dismisses the review Syrus itself filed and recorded a review id for" do
    job.update!(approval_evidence: { "github_review_id" => 555 })
    expect(client).to receive(:dismiss_pr_review)
      .with("acme/widgets", 123, 555, message: "Dismissed via Syrus.")
    expect(client).not_to receive(:pr_reviews)

    result = described_class.call(job: job, user: user)

    expect(job.reload).to be_implemented
    expect(result.review_id).to eq(555)
    expect(result.message).to eq("GitHub review dismissed.")
  end

  it "looks up and dismisses the GitHub review when no github_review_id was ever captured (raw GitHub approval)" do
    job.update!(approval_evidence: {})
    expect(client).to receive(:pr_reviews).with("acme/widgets", 123).and_return([
      Struct.new(:id, :state).new(777, "APPROVED")
    ])
    expect(client).to receive(:dismiss_pr_review)
      .with("acme/widgets", 123, 777, message: "Dismissed via Syrus.")

    result = described_class.call(job: job, user: user)

    expect(job.reload).to be_implemented
    expect(result.review_id).to be_nil
    expect(result.message).to eq("GitHub review dismissed.")
  end
end
