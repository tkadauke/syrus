require "rails_helper"

RSpec.describe ChatSession do
  let(:repo) { Factories.repository }

  it "creates with valid attributes and token defaults" do
    session = described_class.create!(repository: repo, user: repo.user, title: "Plan the aqueduct")

    expect(session).to be_persisted
    expect(session.attached_repositories).to contain_exactly(repo)
    expect(session.repository).to eq(repo)
    expect(session.cumulative_input_tokens).to eq(0)
    expect(session.cumulative_output_tokens).to eq(0)
    expect(session.cumulative_cost).to eq(0)
  end

  it "can exist without an attached repository" do
    session = described_class.new(user: repo.user)

    expect(session).to be_valid
  end

  it "requires a user" do
    session = described_class.new

    expect(session).not_to be_valid
    expect(session.errors[:user]).to be_present
  end

  it "rejects negative usage totals" do
    session = described_class.new(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: -1,
      cumulative_output_tokens: -1,
      cumulative_cost_usd: -0.01
    )

    expect(session).not_to be_valid
    expect(session.errors[:cumulative_input_tokens]).to be_present
    expect(session.errors[:cumulative_output_tokens]).to be_present
    expect(session.errors[:cumulative_cost_usd]).to be_present
  end

  it "reports the cumulative cost supplied by Claude CLI" do
    session = described_class.new(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: 12_400,
      cumulative_output_tokens: 3_200
    )

    expect(session.cumulative_cost).to eq(0)
  end

  it "records turn usage from Claude CLI results without deriving price from tokens" do
    session = described_class.create!(
      repository: repo,
      user: repo.user,
      cumulative_input_tokens: 12_400,
      cumulative_output_tokens: 3_200,
      cumulative_cost_usd: 0.01
    )
    result = AgentInvocation::Result.new(
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: "Done",
      session_id: "claude-session",
      cost_usd: 0.004321,
      input_tokens: 100,
      output_tokens: 25
    )

    session.record_turn_usage!(result)

    expect(session.reload.cumulative_input_tokens).to eq(12_500)
    expect(session.cumulative_output_tokens).to eq(3_225)
    expect(session.cumulative_cost).to eq(BigDecimal("0.014321"))
  end

  it "destroys messages with the session" do
    session = described_class.create!(repository: repo, user: repo.user)
    message = session.messages.create!(role: "user", content: { "text" => "Ave" })

    expect { session.destroy }.to change { ChatMessage.where(id: message.id).count }.by(-1)
  end

  it "lists bookmarks through messages in message chronology" do
    session = described_class.create!(repository: repo, user: repo.user)
    later = session.messages.create!(
      role: "assistant",
      content: { "text" => "Second" },
      created_at: 1.minute.from_now
    )
    earlier = session.messages.create!(
      role: "assistant",
      content: { "text" => "First" },
      created_at: 1.minute.ago
    )
    middle = session.messages.create!(
      role: "assistant",
      content: { "text" => "Middle" },
      created_at: Time.current
    )

    later_bookmark = later.bookmarks.create!(label: "Second topic", kind: "topic")
    earlier_bookmark = earlier.bookmarks.create!(label: "First topic", kind: "manual")
    middle_bookmark = middle.bookmarks.create!(label: "Epic launch", kind: "epic_origin")

    expect(session.bookmarks).to eq([ earlier_bookmark, middle_bookmark, later_bookmark ])
  end

  it "reports a turn in flight until a non-user response follows the latest user message" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect(session).not_to be_turn_in_flight

    session.messages.create!(role: "user", content: { "text" => "Ave" })
    expect(session).to be_turn_in_flight

    session.messages.create!(role: "assistant", content: { "text" => "Salve" })
    expect(session).not_to be_turn_in_flight
  end

  it "is destroyed with its repository" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect { repo.destroy }.to change { described_class.where(id: session.id).count }.by(-1)
  end

  it "is visible from the owning user" do
    session = described_class.create!(repository: repo, user: repo.user)

    expect(repo.user.chat_sessions).to include(session)
  end

  describe "#attached_documents_in_scope" do
    it "returns repository documents reachable through repository, job, and direct document attachments" do
      user = repo.user
      other_repo = Factories.repository(user: user)
      unrelated_repo = Factories.repository(user: user)
      repo_document = repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Repo notes",
        google_docs_url: "https://docs.google.com/document/d/repo/edit"
      )
      job_document = other_repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Job notes",
        google_docs_url: "https://docs.google.com/document/d/job/edit"
      )
      direct_document = unrelated_repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Direct notes",
        google_docs_url: "https://docs.google.com/document/d/direct/edit"
      )
      unrelated_repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Out of scope",
        google_docs_url: "https://docs.google.com/document/d/out/edit"
      )
      job = Factories.job_record(user: user, repository: other_repo)
      session = described_class.create!(user: user, repository: repo)
      session.chat_attachments.create!(attachable: job)
      session.chat_attachments.create!(attachable: direct_document)

      expect(session.attached_documents_in_scope).to contain_exactly(repo_document, job_document, direct_document)
    end
  end
end
