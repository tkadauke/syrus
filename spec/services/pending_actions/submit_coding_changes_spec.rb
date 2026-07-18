require "rails_helper"

RSpec.describe PendingActions::SubmitCodingChanges do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def pending_action(overrides = {})
    chat_session.pending_actions.create!({
      action: "submit_coding_changes",
      payload: {
        "repository_id" => repository.id,
        "branch" => "feature/my-work",
        "title" => "User Profile Page",
        "description" => "Add user profile page"
      },
      requested_by: "agent"
    }.merge(overrides))
  end

  it "enqueues CodingHandoffConfirmJob with the pending action id" do
    action = pending_action

    expect {
      action.confirm!(user: user)
    }.to have_enqueued_job(CodingHandoffConfirmJob).with(action.id)
  end

  it "returns nil so the pending action has no result record after confirmation" do
    action = pending_action

    action.confirm!(user: user)

    expect(action.reload.result).to be_nil
  end

  it "transitions the pending action to confirmed" do
    action = pending_action

    action.confirm!(user: user)

    expect(action.reload).to be_confirmed
  end

  it "raises RecordNotFound when the repository belongs to another user" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    action = pending_action({ payload: { "repository_id" => other_repo.id, "branch" => "main", "title" => "stuff", "description" => "stuff" } })

    expect { action.confirm!(user: user) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "does not enqueue CodingHandoffConfirmJob when the repository is not found" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    action = pending_action({ payload: { "repository_id" => other_repo.id, "branch" => "main", "title" => "stuff", "description" => "stuff" } })

    expect {
      action.confirm!(user: user) rescue nil
    }.not_to have_enqueued_job(CodingHandoffConfirmJob)
  end

  it "validates that repository_id is present in the payload" do
    action = chat_session.pending_actions.build(
      action: "submit_coding_changes",
      payload: { "branch" => "main", "title" => "stuff", "description" => "stuff" },
      requested_by: "agent"
    )

    expect(action).not_to be_valid
    expect(action.errors.to_a).to include(match(/repository_id/))
  end

  it "validates that branch is present in the payload" do
    action = chat_session.pending_actions.build(
      action: "submit_coding_changes",
      payload: { "repository_id" => repository.id, "title" => "stuff", "description" => "stuff" },
      requested_by: "agent"
    )

    expect(action).not_to be_valid
    expect(action.errors.to_a).to include(match(/branch/))
  end

  it "validates that title is present in the payload" do
    action = chat_session.pending_actions.build(
      action: "submit_coding_changes",
      payload: { "repository_id" => repository.id, "branch" => "main", "description" => "stuff" },
      requested_by: "agent"
    )

    expect(action).not_to be_valid
    expect(action.errors.to_a).to include(match(/title/))
  end

  it "validates that description is present in the payload" do
    action = chat_session.pending_actions.build(
      action: "submit_coding_changes",
      payload: { "repository_id" => repository.id, "branch" => "main", "title" => "stuff" },
      requested_by: "agent"
    )

    expect(action).not_to be_valid
    expect(action.errors.to_a).to include(match(/description/))
  end
end
