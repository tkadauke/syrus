require "rails_helper"

RSpec.describe ChatPendingAction do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  it "confirms an add_repo_note action once" do
    action = chat_session.pending_actions.create!(
      action: "add_repo_note",
      payload: { "body" => "Default branch is trunk." }
    )

    expect(action.confirm!).to be true
    expect(action.reload).to be_confirmed
    expect(repository.repository_notes.active.pluck(:body)).to eq([ "Default branch is trunk." ])

    expect(action.confirm!).to be false
    expect(repository.repository_notes.active.count).to eq(1)
  end

  it "confirms a remove_repo_note action" do
    note = repository.repository_notes.create!(body: "Short-lived.", author: "operator")
    action = chat_session.pending_actions.create!(
      action: "remove_repo_note",
      payload: { "id" => note.id }
    )

    expect(action.confirm!).to be true
    expect(note.reload).to be_removed
  end

  it "can reject a pending action without applying it" do
    action = chat_session.pending_actions.create!(
      action: "add_repo_note",
      payload: { "body" => "Do not pin this." }
    )

    expect(action.reject!).to be true
    expect(action.reload).to be_rejected
    expect(repository.repository_notes).to be_empty
  end
end
