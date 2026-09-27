require "rails_helper"

RSpec.describe OperatorBriefing::BlockedDesignDocThreads do
  let(:operator) { Factories.user }
  let(:other_user) { Factories.user }
  let(:doc) { DesignDocs::DesignDoc.create!(owner_user: operator, title: "Briefing", markdown: "Hello") }

  def thread_with_last_comment(author_user:, author_kind: "user")
    anchor = doc.anchors.create!(start_offset: 0, end_offset: 1)
    thread = doc.threads.create!(anchor: anchor, opened_by_user: operator)
    thread.comments.create!(author_kind: author_kind, author_user: author_kind == "user" ? author_user : nil, body: "Please decide.")
    thread
  end

  it "returns open visible threads whose latest comment is not by the operator" do
    waiting = thread_with_last_comment(author_user: other_user)
    answered = thread_with_last_comment(author_user: operator)
    resolved = thread_with_last_comment(author_user: other_user)
    resolved.update!(state: "resolved", resolved_at: Time.current, resolved_by_user: operator)

    expect(described_class.for_user(operator)).to contain_exactly(waiting)
    expect(described_class.for_user(operator)).not_to include(answered, resolved)
  end
end
