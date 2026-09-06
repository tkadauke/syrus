require "rails_helper"

RSpec.describe Mcp::Tools::AssignJobToEpicTool do
  let(:user)         { Factories.user }
  let(:other_user)   { Factories.user }
  let(:repository)   { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def call(job:, epic:)
    described_class.call(job_id: job.id, epic_id: epic.id, server_context: { chat_session: chat_session })
  end

  def response_text(response)
    response.content.first[:text]
  end

  it "assigns the job when the epic has no existing open children" do
    epic = Factories.epic(user: user, repository: repository)
    job = Factories.job_record(user: user, repository: repository, owner_user: other_user)

    response = call(job: job, epic: epic)

    expect(response.error?).to be(false)
    expect(job.reload.epic_id).to eq(epic.id)
  end

  it "assigns the job when its effective owner matches the epic's existing open children" do
    epic = Factories.epic(user: user, repository: repository)
    Factories.job_record(user: user, repository: repository, epic: epic, owner_user: user, state: "queued")
    job = Factories.job_record(user: user, repository: repository, owner_user: user)

    response = call(job: job, epic: epic)

    expect(response.error?).to be(false)
    expect(job.reload.epic_id).to eq(epic.id)
  end

  it "rejects assignment with a clear error when the job's effective owner differs from the epic's open children, without changing the job" do
    epic = Factories.epic(user: user, repository: repository)
    Factories.job_record(user: user, repository: repository, epic: epic, owner_user: user, state: "queued")
    job = Factories.job_record(user: user, repository: repository, owner_user: other_user)

    response = call(job: job, epic: epic)

    expect(response.error?).to be(true)
    expect(response_text(response)).to match(/owned by a different user/)
    expect(job.reload.epic_id).to be_nil
  end
end
