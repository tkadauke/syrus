require "rails_helper"

RSpec.describe ChatProposalOutcomeNotification do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, last_message_at: Time.current) }

  it "builds a confirmed Job notification" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Map auth")
    proposal = chat_session.proposals.create!(
      slug: "auth-map",
      title: "Map auth",
      body: "Map it.",
      state: "confirmed",
      job: job
    )

    expect(described_class.confirmed_message(proposal)).to eq(
      %(Notification: your proposal "Map auth" was confirmed as JOB-#{job.id} (proposal slug: auth-map).)
    )
  end

  it "builds a confirmed Epic notification with child Jobs" do
    epic = Factories.epic(user: user, repository: repository, title: "Ship auth")
    proposal = chat_session.proposals.create!(
      slug: "ship-auth",
      title: "Ship auth",
      body: "Group the auth work.",
      kind: "epic",
      state: "confirmed",
      epic: epic
    )
    schema_job = Factories.job_record(user: user, repository: repository, issue_title: "Auth schema")
    ui_job = Factories.job_record(user: user, repository: repository, issue_number: 43, issue_title: "Auth UI")
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "auth-schema",
      title: "Auth schema",
      body: "Add tables.",
      state: "confirmed",
      job: schema_job
    )
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "auth-ui",
      title: "Auth UI",
      body: "Add screens.",
      state: "confirmed",
      job: ui_job
    )

    expect(described_class.confirmed_message(proposal)).to eq(
      "Notification: your proposal \"Ship auth\" was confirmed as EPIC-#{epic.id} " \
      "with child jobs JOB-#{schema_job.id}, JOB-#{ui_job.id} (proposal slug: ship-auth)."
    )
  end

  it "builds a generic confirmed notification for non-Syrus materializations" do
    proposal = chat_session.proposals.create!(
      slug: "external-issue",
      title: "Open issue",
      body: "File it.",
      kind: "github_issue",
      state: "confirmed"
    )

    expect(described_class.confirmed_message(proposal)).to eq(
      %(Notification: your proposal "Open issue" was confirmed (proposal slug: external-issue).)
    )
  end

  it "builds a rejected notification" do
    proposal = chat_session.proposals.create!(
      slug: "cleanup",
      title: "Clean up",
      body: "Sweep it.",
      state: "rejected"
    )

    expect(described_class.rejected_message(proposal)).to eq(
      %(Notification: your proposal "Clean up" was rejected (proposal slug: cleanup).)
    )
  end
end
