require "rails_helper"

RSpec.describe ChatEpicProposalMaterializer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def epic_proposal
    chat_session.proposals.create!(
      slug: "m3",
      title: "M3 proposals",
      body: "Group cards.",
      kind: "epic",
      repository: repository
    )
  end

  it "materializes the Epic, child Jobs, and sibling Job dependencies in one transaction" do
    proposal = epic_proposal
    schema = proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "schema",
      title: "Schema",
      body: "Persist it.",
      repository: repository
    )
    ui = proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "ui",
      title: "UI",
      body: "Render it.",
      repository: repository
    )
    ChatProposalDependency.create!(proposal: ui, depends_on: schema)

    result = described_class.new(user: user).file!(proposal)

    expect(result.epic).to have_attributes(title: "M3 proposals", repository: repository)
    expect(proposal.reload).to be_confirmed
    expect(proposal.epic).to eq(result.epic)
    expect(result.jobs.map(&:issue_title)).to contain_exactly("Schema", "UI")
    expect(result.jobs).to all(be_blocked_by_epic)
    expect(result.jobs).to all(have_attributes(epic: result.epic))
    expect(ui.reload.job.dependencies.first.depends_on_job).to eq(schema.reload.job)
  end

  it "excludes rejected child Jobs from materialization" do
    proposal = epic_proposal
    kept = proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "kept",
      title: "Kept",
      body: "Build it.",
      repository: repository
    )
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "rejected",
      title: "Rejected",
      body: "Do not build it.",
      repository: repository,
      state: "rejected",
      rejected_at: Time.current
    )

    result = described_class.new(user: user).file!(proposal)

    expect(result.jobs.size).to eq(1)
    expect(result.jobs.first.issue_title).to eq("Kept")
    expect(kept.reload).to be_confirmed
    expect(chat_session.proposals.find_by!(slug: "rejected")).to be_rejected
  end

  it "rolls back the Epic when a child Job cannot be created" do
    other_repository = Factories.repository(user: user)
    proposal = epic_proposal
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "good",
      title: "Good",
      body: "Same repo.",
      repository: repository
    )
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "bad",
      title: "Bad",
      body: "Different repo.",
      repository: other_repository
    )

    expect {
      expect {
        described_class.new(user: user).file!(proposal)
      }.to raise_error(ActiveRecord::RecordInvalid, /Epic must belong to the same repository/)
    }.to change(Epic, :count).by(0).and change(Job, :count).by(0)

    expect(proposal.reload).to be_proposed
    expect(proposal.epic).to be_nil
  end
end
