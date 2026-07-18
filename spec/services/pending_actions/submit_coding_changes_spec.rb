require "rails_helper"

RSpec.describe PendingActions::SubmitCodingChanges do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def enable_coding_mode!
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: true)
  end

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

  before { enable_coding_mode! }

  it "enqueues CodingHandoffConfirmJob on confirmation" do
    action = pending_action

    expect { action.confirm!(user: user) }.to have_enqueued_job(CodingHandoffConfirmJob).with(action.id)
  end

  it "confirms the pending action with a nil result (handoff completes asynchronously)" do
    action = pending_action

    action.confirm!(user: user)

    expect(action.reload).to be_confirmed
    expect(action.result).to be_nil
  end

  it "raises RecordNotFound when the repository belongs to another user" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    action = pending_action({ payload: { "repository_id" => other_repo.id, "branch" => "main", "title" => "stuff", "description" => "stuff" } })

    expect { action.confirm!(user: user) }.to raise_error(ActiveRecord::RecordNotFound)
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
