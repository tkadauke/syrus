require "rails_helper"

RSpec.describe AppEvents do
  it "broadcasts a stable JSON event envelope to the user's app channel" do
    user = Factories.user
    occurred_at = Time.zone.local(2026, 5, 30, 12, 0, 1, 123_000)

    allow(AppUserChannel).to receive(:broadcast_to)

    described_class.broadcast(
      user: user,
      type: "job.updated",
      resource: "job",
      id: 42,
      changed: %i[state pr_number],
      payload: { "state" => "running" },
      revision: 7,
      occurred_at: occurred_at
    )

    expect(AppUserChannel).to have_received(:broadcast_to).with(
      user,
      {
        "type" => "job.updated",
        "resource" => "job",
        "id" => 42,
        "sequence" => 1,
        "changed" => %w[state pr_number],
        "occurred_at" => "2026-05-30T12:00:01.123Z",
        "revision" => 7,
        "payload" => { "state" => "running" }
      }
    )
  end

  it "omits revision when the caller doesn't pass one" do
    user = Factories.user
    allow(AppUserChannel).to receive(:broadcast_to)

    described_class.broadcast(user: user, type: "epic.updated", resource: "epic", id: 1)

    expect(AppUserChannel).to have_received(:broadcast_to).with(user, hash_excluding("revision"))
  end

  it "stamps a per-user monotonically increasing sequence across broadcasts" do
    user = Factories.user
    other_user = Factories.user
    broadcasts = []
    allow(AppUserChannel).to receive(:broadcast_to) { |target, event| broadcasts << [ target, event ] }

    3.times { described_class.broadcast(user: user, type: "job.updated", resource: "job", id: 1) }
    described_class.broadcast(user: other_user, type: "job.updated", resource: "job", id: 1)

    user_sequences = broadcasts.select { |target, _event| target == user }.map { |_target, event| event["sequence"] }
    other_user_sequences = broadcasts.select { |target, _event| target == other_user }.map { |_target, event| event["sequence"] }

    expect(user_sequences).to eq([ 1, 2, 3 ])
    expect(other_user_sequences).to eq([ 1 ])
  end

  describe ".broadcast_job_resource" do
    it "broadcasts a sequence-less event envelope to the job-scoped stream, never to the user channel" do
      occurred_at = Time.zone.local(2026, 5, 30, 12, 0, 1, 123_000)
      allow(ActionCable.server).to receive(:broadcast)
      allow(AppUserChannel).to receive(:broadcast_to)

      described_class.broadcast_job_resource(
        job_id: 9,
        type: "workflow.updated",
        resource: "workflow",
        id: 5,
        changed: %i[state],
        payload: { fields: { state: "running" } },
        revision: 3,
        occurred_at: occurred_at
      )

      expect(ActionCable.server).to have_received(:broadcast).with(
        "job_resource:9",
        {
          "type" => "workflow.updated",
          "resource" => "workflow",
          "id" => 5,
          "job_id" => 9,
          "changed" => %w[state],
          "occurred_at" => "2026-05-30T12:00:01.123Z",
          "revision" => 3,
          "payload" => { "fields" => { "state" => "running" } }
        }
      )
      expect(AppUserChannel).not_to have_received(:broadcast_to)
    end

    it "matches the stream JobChannel subscribes to" do
      expect(JobChannel.stream_name(9)).to eq("job_resource:9")
    end
  end

  describe ".broadcast_chat_resource" do
    it "broadcasts a sequence-less event envelope only to current participants' streams" do
      owner = Factories.user
      removed_user = Factories.user
      chat = ChatSession.create!(user: owner, conversation_kind: "group")
      removed_participant = chat.chat_participants.create!(user: removed_user, role: "member")
      removed_participant.destroy!
      allow(ActionCable.server).to receive(:broadcast)
      allow(AppUserChannel).to receive(:broadcast_to)

      described_class.broadcast_chat_resource(
        chat_session_id: chat.id,
        type: "updated",
        resource: "chat",
        id: chat.id,
        changed: %w[messages],
        payload: { action: "replace_tail" }
      )

      expect(ActionCable.server).to have_received(:broadcast).with(
        ChatChannel.stream_name(chat.id, owner.id),
        hash_including(
          "type" => "updated",
          "resource" => "chat",
          "id" => chat.id,
          "changed" => %w[messages],
          "payload" => { "action" => "replace_tail" }
        )
      )
      expect(ActionCable.server).not_to have_received(:broadcast).with(
        ChatChannel.stream_name(chat.id, removed_user.id),
        anything
      )
      expect(AppUserChannel).not_to have_received(:broadcast_to)
    end

    it "matches the stream ChatChannel subscribes to" do
      expect(ChatChannel.stream_name(4, 9)).to eq("chat_resource:4:user:9")
    end
  end

  describe "delivery metrics" do
    around do |example|
      original_registry = Syrus::Metrics.registry
      Syrus::Metrics.reset!
      described_class.declare_metrics!
      example.run
    ensure
      Syrus::Metrics.instance_variable_set(:@registry, original_registry)
    end

    def delivered_by_resource
      Syrus::Metrics.counter(:syrus_app_events_delivered_total).samples
        .to_h { |labels, value| [ labels[:resource], value ] }
    end

    it "counts every broadcast path (user channel, job resource, chat resource) by resource" do
      allow(AppUserChannel).to receive(:broadcast_to)
      allow(ActionCable.server).to receive(:broadcast)

      described_class.broadcast(user: Factories.user, type: "job.updated", resource: "job", id: 1)
      described_class.broadcast_job_resource(job_id: 1, type: "workflow.updated", resource: "workflow", id: 2)
      described_class.broadcast_chat_resource(chat_session_id: 1, type: "updated", resource: "chat", id: 1)
      described_class.broadcast_job_resource(job_id: 1, type: "workflow.updated", resource: "workflow", id: 3)

      expect(delivered_by_resource).to eq("job" => 1, "workflow" => 2, "chat" => 1)
    end
  end
end
