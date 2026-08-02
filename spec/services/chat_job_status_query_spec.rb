require "rails_helper"

RSpec.describe ChatJobStatusQuery do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:session) { ChatSession.create!(repository: repository, user: user) }

  def confirmed_job_proposal(title:, **job_attrs)
    job = Factories.job_record(user: user, repository: repository, **job_attrs)
    proposal = ChatProposal.create!(
      chat_session: session,
      slug: "proposal-#{SecureRandom.hex(4)}",
      title: title,
      body: "Body",
      kind: "job",
      state: "confirmed",
      job: job
    )
    [ proposal, job ]
  end

  def count_sql
    count = 0
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA"
      next if payload[:cached]

      count += 1
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end

  describe "#call" do
    it "returns an empty array when there are no proposals and no direct linked jobs" do
      expect(described_class.call(session)).to eq([])
    end

    it "includes jobs from confirmed proposals" do
      _, job = confirmed_job_proposal(title: "Proposal Job")

      result = described_class.call(session)

      expect(result.length).to eq(1)
      expect(result.first).to include(kind: "job", job_id: job.id, title: job.title)
    end

    it "includes direct jobs linked to the session via linked_chat_id" do
      job = Factories.job_record(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        linked_chat_id: session.id
      )

      result = described_class.call(session)

      expect(result.length).to eq(1)
      expect(result.first).to include(kind: "job", job_id: job.id)
    end

    it "does not include direct linked jobs from other chat sessions" do
      other_session = ChatSession.create!(repository: repository, user: user)
      Factories.job_record(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        linked_chat_id: other_session.id
      )

      expect(described_class.call(session)).to be_empty
    end

    it "does not duplicate a job that is both proposal-linked and directly linked" do
      proposal = ChatProposal.create!(
        chat_session: session,
        slug: "dup-#{SecureRandom.hex(4)}",
        title: "Duplicate Job",
        body: "Body",
        kind: "job",
        state: "confirmed"
      )
      job = Factories.job_record(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        linked_chat_id: session.id
      )
      proposal.update!(job: job)

      result = described_class.call(session)

      expect(result.length).to eq(1)
      expect(result.first[:job_id]).to eq(job.id)
    end

    it "returns both proposal jobs and direct linked jobs together" do
      _, proposal_job = confirmed_job_proposal(title: "Proposal Job")
      direct_job = Factories.job_record(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        linked_chat_id: session.id
      )

      result = described_class.call(session)

      job_ids = result.map { |r| r[:job_id] }
      expect(job_ids).to contain_exactly(proposal_job.id, direct_job.id)
    end

    it "does not include non-direct jobs linked to the session" do
      Factories.job_record(
        user: user,
        repository: repository,
        kind: "issue",
        linked_chat_id: session.id
      )

      expect(described_class.call(session)).to be_empty
    end

    it "includes workflow_step for a running direct linked job" do
      job = Factories.job_record(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        linked_chat_id: session.id,
        state: "open"
      )
      workflow = Workflow.create!(
        job: job,
        user: user,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running"
      )
      Step.create!(
        workflow: workflow,
        kind: "implement",
        state: "running",
        position: 1
      )

      result = described_class.call(session)

      expect(result.first[:workflow_step]).to eq("implement")
      expect(result.first[:active_workflow]).to include(
        id: workflow.id,
        slug: workflow.slug,
        state: "running",
        trigger_kind: "initial",
        step: "implement"
      )
    end

    it "includes active queued workflows and suppresses awaiting review blockers" do
      _, job = confirmed_job_proposal(title: "Feedback Job", state: "implemented")
      workflow = Workflow.create!(
        job: job,
        user: user,
        trigger_kind: "chat_feedback",
        agent_provider: "claude",
        state: "queued"
      )

      result = described_class.call(session)

      expect(result.first[:workflow_step]).to eq("chat_feedback")
      expect(result.first[:active_workflow]).to include(
        id: workflow.id,
        state: "queued",
        trigger_kind: "chat_feedback",
        step: "chat_feedback"
      )
      expect(result.first[:blocker]).to be_nil
    end

    it "preloads workflow state for many jobs without per-job workflow queries" do
      12.times do |index|
        _, job = confirmed_job_proposal(title: "Proposal Job #{index}", state: "running")
        workflow = Workflow.create!(
          job: job,
          user: user,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: "running"
        )
        Step.create!(
          workflow: workflow,
          kind: "implement",
          state: "running",
          position: 1
        )
      end

      sql_count = count_sql { described_class.call(session) }

      expect(sql_count).to be <= 12
    end
  end
end
