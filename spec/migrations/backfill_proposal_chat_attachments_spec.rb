require "rails_helper"
require Rails.root.join("db/migrate/20260624131211_backfill_proposal_chat_attachments")

RSpec.describe BackfillProposalChatAttachments do
  let(:migration) { described_class.new }

  it "creates missing attachments for confirmed proposal Jobs and Epics idempotently" do
    user = Factories.user
    repository = Factories.repository(user: user)
    chat_session = ChatSession.create!(user: user, repository: repository)
    job = Factories.job_record(user: user, repository: repository, issue_number: 7)
    epic = Factories.epic(user: user, repository: repository)

    chat_session.proposals.create!(
      slug: "job-proposal",
      title: "Job proposal",
      body: "Build it.",
      state: "confirmed",
      job: job
    )
    chat_session.proposals.create!(
      slug: "epic-proposal",
      title: "Epic proposal",
      body: "Group it.",
      kind: "epic",
      state: "confirmed",
      epic: epic
    )

    expect(chat_session.reload.attached_jobs).to be_empty
    expect(chat_session.attached_epics).to be_empty

    migration.up
    migration.up

    expect(chat_session.reload.attached_jobs).to contain_exactly(job)
    expect(chat_session.attached_epics).to contain_exactly(epic)
    expect(chat_session.job_attachments.count).to eq(1)
    expect(chat_session.epic_attachments.count).to eq(1)
  end
end
