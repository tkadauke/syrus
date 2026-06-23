require "rails_helper"

RSpec.describe App::ChatMessagePayload do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }

  it "returns materialized job details for a confirmed job proposal" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Add inspection tools", state: "open")
    proposal = chat.proposals.create!(
      repository: repository,
      job: job,
      kind: "job",
      state: "confirmed",
      slug: "inspection-tools",
      title: "Add inspection tools",
      body: "Inspect more."
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal confirmed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:materialized)).to eq(
      kind: "job",
      job_id: job.id,
      job_title: "Add inspection tools",
      job_state: "open"
    )
  end

  it "returns materialized epic details and child jobs for a confirmed epic bundle" do
    epic = Factories.epic(user: user, repository: repository, title: "Chat-driven job feedback loop")
    parent = chat.proposals.create!(
      repository: repository,
      epic: epic,
      kind: "epic",
      state: "confirmed",
      slug: "feedback-loop",
      title: "Chat-driven job feedback loop",
      body: "Bundle the work."
    )
    child_job = Factories.job_record(user: user, repository: repository, issue_title: "Add trigger", state: "queued")
    chat.proposals.create!(
      repository: repository,
      parent_proposal: parent,
      job: child_job,
      kind: "job",
      state: "confirmed",
      slug: "add-trigger",
      title: "Add trigger",
      body: "Trigger it."
    )
    message = chat.messages.create!(role: "assistant", proposal: parent, content: { "text" => "Epic proposal confirmed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:materialized)).to eq(
      kind: "epic",
      epic_id: epic.id,
      epic_title: "Chat-driven job feedback loop",
      child_jobs: [
        { job_id: child_job.id, title: "Add trigger" }
      ]
    )
  end

  it "returns dependency details for a proposal" do
    dependency = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "confirmed",
      slug: "chat-search-fts5",
      title: "Chat full-text search via dedicated SQLite FTS5 database",
      body: "Add search."
    )
    dependent = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "proposed",
      slug: "chat-search-ui",
      title: "Chat search UI",
      body: "Expose search."
    )
    ChatProposalDependency.create!(proposal: dependent, depends_on: dependency)
    dependency_message = chat.messages.create!(role: "assistant", proposal: dependency, content: { "text" => "Dependency proposed." })
    message = chat.messages.create!(role: "assistant", proposal: dependent, content: { "text" => "Dependent proposed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:has_dependencies)).to be(true)
    expect(payload.fetch(:dependency_slugs)).to eq([ "chat-search-fts5" ])
    expect(payload.fetch(:dependencies)).to eq([
      {
        slug: "chat-search-fts5",
        title: "Chat full-text search via dedicated SQLite FTS5 database",
        state: "confirmed",
        confirmed: true,
        anchor_message_id: dependency_message.id,
        materialized_path: nil
      }
    ])
  end

  it "returns empty dependency details when a proposal has no dependencies" do
    proposal = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "proposed",
      slug: "chat-search-ui",
      title: "Chat search UI",
      body: "Expose search."
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal created." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:has_dependencies)).to be(false)
    expect(payload.fetch(:dependencies)).to eq([])
  end
end
