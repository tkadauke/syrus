require "rails_helper"

RSpec.describe Mcp::Tools::RemoveJobFromEpicTool, :full_chat_access do
  let(:user)         { Factories.user }
  let(:repository)   { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def call(job)
    described_class.call(job_id: job.id, server_context: { chat_session: chat_session })
  end

  it "removes an ordinary job from its epic" do
    epic = Factories.epic(user: user, repository: repository)
    job = Factories.job_record(user: user, repository: repository, epic: epic, state: "queued")

    expect(call(job).error?).to be(false)
    expect(job.reload.epic_id).to be_nil
  end

  it "can clear a legacy invalid epic membership from a main_grader job" do
    epic = Factories.epic(user: user, repository: repository)
    job = repository.jobs.create!(user: user, kind: "main_grader")
    job.update_columns(epic_id: epic.id)

    expect(call(job).error?).to be(false)
    expect(job.reload.epic_id).to be_nil
  end
end
