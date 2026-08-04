require "rails_helper"

RSpec.describe SpawnedProcess do
  let(:user) { Factories.user }
  let(:base_attrs) do
    {
      kind: "agent",
      command: "claude --print",
      hostname: "syrus-worker-test",
      started_at: Time.current
    }
  end

  it "creates rows for every known kind" do
    SpawnedProcess::KINDS.each do |kind|
      sp = described_class.create!(base_attrs.merge(kind: kind))
      expect(sp).to be_valid
      expect(sp.running?).to be true
    end
  end

  it "refuses to create rows with unknown kinds" do
    expect {
      described_class.create!(base_attrs.merge(kind: "mcp_sidecar"))
    }.to raise_error(ActiveRecord::RecordInvalid, /KINDS/)
  end

  it "rejects unknown outcomes on finalize" do
    sp = described_class.create!(base_attrs)
    expect {
      sp.update!(finished_at: Time.current, outcome: "exploded")
    }.to raise_error(ActiveRecord::RecordInvalid, /Outcome/i)
  end

  it "exposes running? / finished? from finished_at" do
    sp = described_class.create!(base_attrs)
    expect(sp).to be_running
    sp.update!(finished_at: Time.current, outcome: "succeeded")
    expect(sp).to be_finished
  end

  it "treats a row with no chunks past the threshold as stale" do
    sp = described_class.create!(base_attrs.merge(started_at: 10.minutes.ago))
    expect(sp).to be_stale
  end

  it "is not stale once finalized" do
    sp = described_class.create!(base_attrs.merge(started_at: 10.minutes.ago, finished_at: Time.current, outcome: "succeeded"))
    expect(sp).not_to be_stale
  end

  it "request_kill! stamps the timestamp and operator id" do
    sp = described_class.create!(base_attrs)
    sp.request_kill!(user: user)
    sp.reload
    expect(sp.kill_requested_at).to be_present
    expect(sp.kill_requested_by_user).to eq(user)
  end

  it "redacts GitHub credentials from command display text" do
    sp = described_class.create!(
      base_attrs.merge(
        command: "git fetch https://x-access-token:ghp_secret@github.com/acme/widgets.git github_pat_11ABC"
      )
    )

    expect(sp.redacted_command).to eq(
      "git fetch https://x-access-token:[REDACTED]@github.com/acme/widgets.git [REDACTED]"
    )
    expect(sp.redacted_command).not_to include("ghp_secret")
    expect(sp.redacted_command).not_to include("github_pat_11ABC")
  end

  describe ".stale" do
    it "scopes to running rows whose heartbeat is older than the threshold" do
      fresh = described_class.create!(base_attrs.merge(last_chunk_at: 1.minute.ago))
      stale = described_class.create!(base_attrs.merge(last_chunk_at: 10.minutes.ago))
      described_class.create!(base_attrs.merge(finished_at: Time.current, outcome: "succeeded"))

      expect(described_class.stale).to contain_exactly(stale)
      expect(described_class.stale).not_to include(fresh)
    end
  end
end
