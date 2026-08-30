require "rails_helper"

RSpec.describe PendingActions::CompleteImplementStep do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  def enable_coding_mode!
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: true)
  end

  def enable_local_mode!
    feature = Feature.find_or_create_by!(slug: "local_mode") do |record|
      record.category = "Labs"
      record.name = "Local Mode"
    end
    feature.update!(enabled: true)
  end

  def pending_action(job, branch_name: nil)
    payload = { "job_id" => job.id }
    payload["branch_name"] = branch_name if branch_name
    chat_session.pending_actions.create!(
      action: "complete_implement_step",
      payload: payload,
      requested_by: "agent"
    )
  end

  before { enable_coding_mode! }

  it "dispatches a coding_handoff workflow and stores it as the result" do
    job = Factories.job_record(user: user, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/job-1", pr_number: 10)
    action = pending_action(job)

    allow(WorkUnits::Launcher).to receive(:start!).and_call_original
    action.confirm!(user: user)

    expect(action.reload).to be_confirmed
    expect(action.result).to be_a(Workflow)
    expect(action.result.trigger_kind).to eq("coding_handoff")
    expect(action.result.work_unit).to be_present
    expect(WorkUnits::Launcher).to have_received(:start!).with(action.result)
  end

  it "transitions the coding mode job out of coding state while keeping the chat link for grader feedback" do
    job = Factories.job_record(user: user, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/job-1", pr_number: 10)
    action = pending_action(job)

    allow(WorkUnits::Launcher).to receive(:start!).and_call_original
    action.confirm!(user: user)

    expect(job.reload).not_to be_coding
    expect(job.linked_chat_id).to eq(chat_session.id)
  end

  it "dispatches a local_mode_handoff workflow with the confirmed branch" do
    chat_session.update!(mode: "local")
    enable_local_mode!
    job = Factories.job_record(user: user, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: nil, pr_number: nil)
    action = pending_action(job, branch_name: "syrus/local-fix")

    allow(WorkUnits::Launcher).to receive(:start!).and_call_original
    action.confirm!(user: user)

    expect(action.reload).to be_confirmed
    expect(action.result).to be_a(Workflow)
    expect(action.result.trigger_kind).to eq("local_mode_handoff")
    expect(job.reload).not_to be_coding
    expect(job.branch_name).to eq("syrus/local-fix")
    expect(WorkUnits::Launcher).to have_received(:start!).with(action.result)
  end

  it "raises ArgumentError when branch_name is missing for a new job without a PR" do
    job = Factories.job_record(user: user, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: nil, pr_number: nil)
    action = pending_action(job)

    expect { action.confirm!(user: user) }.to raise_error(ArgumentError, /branch_name is required/)
  end

  it "rejects invalid branch_name payloads before confirmation" do
    job = Factories.job_record(user: user, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, pr_number: 10)

    expect { pending_action(job, branch_name: "bad branch") }
      .to raise_error(ActiveRecord::RecordInvalid, /branch_name is not a valid branch name/)
  end

  it "raises ArgumentError when the job is not in coding state" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    action = pending_action(job)

    expect { action.confirm!(user: user) }.to raise_error(ArgumentError, /not in coding state/)
  end

  it "raises ArgumentError when the job is linked to a different chat session" do
    other_chat = ChatSession.create!(user: user, repository: repository, mode: "coding")
    job = Factories.job_record(user: user, repository: repository, state: "coding",
                               linked_chat_id: other_chat.id)
    action = pending_action(job)

    expect { action.confirm!(user: user) }.to raise_error(ArgumentError, /not linked to this chat session/)
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
