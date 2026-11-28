require "rails_helper"

RSpec.describe ChatAssociatedJobs do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(repository: repository, user: user) }
  let(:other_chat) { ChatSession.create!(repository: repository, user: user) }

  def proposal!(chat_session, job, state: "confirmed", kind: "job")
    ChatProposal.create!(chat_session: chat_session, slug: "p-#{SecureRandom.hex(4)}", title: "T", body: "B",
      kind: kind, state: state, job: job)
  end

  let!(:proposed) { Factories.job_record(user: user, repository: repository).tap { |job| proposal!(chat, job) } }
  let!(:unconfirmed) { Factories.job_record(user: user, repository: repository).tap { |job| proposal!(chat, job, state: "proposed") } }
  let!(:direct) { Factories.job_record(user: user, repository: repository, kind: "direct", issue_number: nil, linked_chat_id: chat.id) }
  let!(:elsewhere) { Factories.job_record(user: user, repository: repository).tap { |job| proposal!(other_chat, job) } }

  it "matches the relation form for a single chat" do
    expect(described_class.scope(chat).pluck(:id)).to contain_exactly(proposed.id, direct.id)
    expect(described_class.scope_for(ChatSession.where(id: chat.id)).pluck(:id)).to contain_exactly(proposed.id, direct.id)
  end

  # The relation form ORs two IN-subqueries, which MySQL answers with a full
  # scan of jobs (~105 ms per call in production). The single-chat scope
  # resolves ids with indexed lookups and filters jobs by primary key only.
  it "queries jobs by id rather than ORing subqueries" do
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] if payload[:sql].match?(/\bFROM\s+.?jobs.?\b/i) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.scope(chat).to_a }

    final = statements.last
    expect(final).not_to match(/\bOR\b/i)
    expect(final).not_to match(/chat_proposals/i)
  end
end
