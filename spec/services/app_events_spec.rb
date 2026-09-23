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
end
