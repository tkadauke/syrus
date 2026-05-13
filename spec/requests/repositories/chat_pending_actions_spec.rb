require "rails_helper"

RSpec.describe "Repository chat pending actions", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repo) }

  before { sign_in_as(user) }

  def pending_action
    ChatPendingAction.create!(
      user: user,
      repository: repo,
      chat_session: chat_session,
      action_type: "schedule_recurring",
      payload: {
        "cron_expression" => "0 9 * * *",
        "label" => "Daily review",
        "prompt" => "Review the project."
      }
    )
  end

  it "confirms a pending recurring schedule action" do
    action = pending_action

    expect {
      post repository_chat_pending_action_confirm_path(repo, action)
    }.to change { RecurringTask.count }.by(1)

    expect(response).to redirect_to(repository_chats_path(repo))
    expect(action.reload).to be_confirmed
  end

  it "cancels a pending action" do
    action = pending_action

    delete repository_chat_pending_action_path(repo, action)

    expect(response).to redirect_to(repository_chats_path(repo))
    expect(action.reload).to be_cancelled
  end
end
