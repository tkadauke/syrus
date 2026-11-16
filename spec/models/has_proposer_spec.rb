require "rails_helper"

RSpec.describe HasProposer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  it "leaves proposer columns null for an issue-ingested Job" do
    job = Job.create!(user: user, repository: repository, issue_number: 42)

    expect(job).to have_attributes(proposer: nil, proposer_type: nil, proposer_id: nil)
  end

  it "returns nil after a referenced proposer record is deleted" do
    proposer = Factories.user(email_address: "deleted-proposer@example.com")
    job = Job.create!(user: user, repository: repository, issue_number: 43, proposer: proposer)
    proposer_id = proposer.id

    User.where(id: proposer_id).delete_all

    expect(job.reload.proposer).to be_nil
    expect(job).to have_attributes(proposer_type: "User", proposer_id: proposer_id)
  end
end
