require "rails_helper"

RSpec.describe BroadcastsJobProgress do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }
  let(:chat_session) { ChatSession.create!(user: user) }

  before do
    allow(AppUserChannel).to receive(:broadcast_to)
  end

  it "broadcasts a job update when a Workflow is created" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")

    expect(AppUserChannel).to have_received(:broadcast_to).with(
      user,
      hash_including(
        "type" => "job.updated",
        "resource" => "job",
        "id" => job.id,
        "changed" => include("workflow.created", "id", "job_id", "trigger_kind")
      )
    )
    expect(workflow).to be_persisted
  end

  it "broadcasts a job update when a Step changes progress state" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    RSpec::Mocks.space.proxy_for(AppUserChannel).reset
    allow(AppUserChannel).to receive(:broadcast_to)

    step.start!
    step.save!

    expect(AppUserChannel).to have_received(:broadcast_to).with(
      user,
      hash_including(
        "type" => "job.updated",
        "resource" => "job",
        "id" => job.id,
        "changed" => include("step.updated", "state", "started_at")
      )
    )
  end

  it "broadcasts a job update when a Run changes progress state" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "running")
    RSpec::Mocks.space.proxy_for(AppUserChannel).reset
    allow(AppUserChannel).to receive(:broadcast_to)

    run.succeed!
    run.save!

    expect(AppUserChannel).to have_received(:broadcast_to).with(
      user,
      hash_including(
        "type" => "job.updated",
        "resource" => "job",
        "id" => job.id,
        "changed" => include("run.updated", "state", "finished_at")
      )
    )
  end

  it "does not broadcast for heartbeat-only Run updates" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "running")
    RSpec::Mocks.space.proxy_for(AppUserChannel).reset
    allow(AppUserChannel).to receive(:broadcast_to)

    run.update!(last_heartbeat_at: Time.current)

    expect(AppUserChannel).not_to have_received(:broadcast_to)
  end

  describe "chat session broadcasts" do
    it "broadcasts a chat.updated event to confirmed chat sessions linked to the job" do
      ChatProposal.create!(
        chat_session: chat_session,
        job: job,
        kind: "job",
        state: "confirmed",
        slug: "linked-proposal",
        title: "Linked proposal",
        body: "Do the thing."
      )

      Workflow.create!(job: job, trigger_kind: "initial")

      expect(AppUserChannel).to have_received(:broadcast_to).with(
        user,
        hash_including(
          "type" => "chat.updated",
          "resource" => "chat",
          "id" => chat_session.id,
          "payload" => { "action" => "job_status_changed", "job_id" => job.id }
        )
      )
    end

    it "does not broadcast a chat.updated event when no confirmed proposals link the job" do
      ChatProposal.create!(
        chat_session: chat_session,
        job: job,
        kind: "job",
        state: "proposed",
        slug: "unconfirmed-proposal",
        title: "Unconfirmed proposal",
        body: "Not yet confirmed."
      )

      Workflow.create!(job: job, trigger_kind: "initial")

      expect(AppUserChannel).not_to have_received(:broadcast_to).with(
        user,
        hash_including("type" => "chat.updated")
      )
    end

    it "broadcasts a chat.updated event when a direct job is linked to the chat session" do
      job.update!(kind: "direct", issue_number: nil, linked_chat_id: chat_session.id)

      Workflow.create!(job: job, trigger_kind: "chat_feedback")

      expect(AppUserChannel).to have_received(:broadcast_to).with(
        user,
        hash_including(
          "type" => "chat.updated",
          "resource" => "chat",
          "id" => chat_session.id,
          "payload" => { "action" => "job_status_changed", "job_id" => job.id }
        )
      )
    end

    it "broadcasts to each distinct chat session exactly once when multiple proposals link the same session" do
      2.times do |i|
        ChatProposal.create!(
          chat_session: chat_session,
          job: job,
          kind: "job",
          state: "confirmed",
          slug: "proposal-#{i}",
          title: "Proposal #{i}",
          body: "The #{i}th proposal."
        )
      end

      Workflow.create!(job: job, trigger_kind: "initial")

      expect(AppUserChannel).to have_received(:broadcast_to).with(
        user,
        hash_including("type" => "chat.updated", "id" => chat_session.id)
      ).once
    end
  end
end
