require "rails_helper"

RSpec.describe PendingActions::CompleteImplementStep do
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

  def pending_action(job)
    chat_session.pending_actions.create!(
      action: "complete_implement_step",
      payload: { "job_id" => job.id },
      requested_by: "agent"
    )
  end

  before { enable_coding_mode! }

  it "dispatches a coding_handoff workflow and stores it as the result" do
    job = Factories.job_record(user: user, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id)
    action = pending_action(job)

    allow(StepDispatcher).to receive(:start_workflow)
    action.confirm!(user: user)

    expect(action.reload).to be_confirmed
    expect(action.result).to be_a(Workflow)
    expect(action.result.trigger_kind).to eq("coding_handoff")
  end

  it "transitions the job out of coding state" do
    job = Factories.job_record(user: user, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id)
    action = pending_action(job)

    allow(StepDispatcher).to receive(:start_workflow)
    action.confirm!(user: user)

    expect(job.reload).not_to be_coding
  end

  it "raises ArgumentError when the job is not in coding state" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    action = pending_action(job)

    expect { action.confirm!(user: user) }.to raise_error(ArgumentError, /not in coding state/)
  end

  it "raises RecordNotFound when the job belongs to another user" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    other_job = Factories.job_record(user: other_user, repository: other_repo, state: "coding")
    action = chat_session.pending_actions.create!(
      action: "complete_implement_step",
      payload: { "job_id" => other_job.id },
      requested_by: "agent"
    )

    expect { action.confirm!(user: user) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
