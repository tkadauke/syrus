require "rails_helper"

RSpec.describe RuntimeControlLease, type: :model do
  let(:repository) { Factories.repository }

  def build_session(**attrs)
    RuntimeSession.create!({
      repository: repository,
      workspace_ref: "workspace-#{SecureRandom.hex(4)}",
      provider_key: "browser",
      display_name: "Browser",
      state: "running"
    }.merge(attrs))
  end

  describe ".acquire!" do
    it "creates an active lease with acquired_at/expires_at set and a default duration" do
      session = build_session

      freeze_time do
        lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input", reason: "click a button")

        expect(lease).to be_active
        expect(lease.state).to eq("active")
        expect(lease.owner).to eq("agent")
        expect(lease.mode).to eq("input")
        expect(lease.reason).to eq("click a button")
        expect(lease.acquired_at).to eq(Time.current)
        expect(lease.expires_at).to eq(described_class::DEFAULT_DURATION.from_now)
        expect(lease.cancellable).to be true
      end
    end

    it "clamps an out-of-range requested duration into [MIN_DURATION, MAX_DURATION]" do
      session = build_session

      freeze_time do
        short = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input", duration_seconds: 1)
        long = described_class.acquire!(runtime_session: build_session, owner: "agent", mode: "input", duration_seconds: 3600)

        expect(short.expires_at).to eq(described_class::MIN_DURATION.from_now)
        expect(long.expires_at).to eq(described_class::MAX_DURATION.from_now)
      end
    end

    it "raises ArgumentError for observe_only, which never requires a lease" do
      session = build_session

      expect {
        described_class.acquire!(runtime_session: session, owner: "agent", mode: "observe_only")
      }.to raise_error(ArgumentError)
    end

    it "raises Conflict when another active lease already holds the input serialization group" do
      session = build_session
      described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      expect {
        described_class.acquire!(runtime_session: session, owner: "user", mode: "input")
      }.to raise_error(RuntimeControlLease::Conflict)
    end

    it "serializes build and lifecycle together, distinct from input" do
      session = build_session
      described_class.acquire!(runtime_session: session, owner: "agent", mode: "build")

      expect {
        described_class.acquire!(runtime_session: session, owner: "agent", mode: "lifecycle")
      }.to raise_error(RuntimeControlLease::Conflict)

      # A concurrent input lease is unaffected -- different serialization group.
      expect {
        described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")
      }.not_to raise_error
    end

    it "allows a new lease once the prior one in the same group has ended" do
      session = build_session
      first = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")
      first.release!

      expect {
        described_class.acquire!(runtime_session: session, owner: "user", mode: "input")
      }.not_to raise_error
    end
  end

  describe "validations" do
    it "rejects unknown owner, mode, or state values" do
      session = build_session
      lease = described_class.new(runtime_session: session, owner: "nobody", mode: "teleport", state: "vibing")

      expect(lease).not_to be_valid
      expect(lease.errors.attribute_names).to include(:owner, :mode, :state)
    end
  end

  describe "#release!" do
    it "transitions to released and records released_at" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      freeze_time do
        lease.release!
        expect(lease.state).to eq("released")
        expect(lease.released_at).to eq(Time.current)
      end
    end

    it "is broadcast on the session's control channel" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      broadcasts = []
      allow(ActionCable.server).to receive(:broadcast) { |stream, msg| broadcasts << [ stream, msg ] }

      lease.release!

      expect(broadcasts).to include([
        "runtime_session_#{session.id}_control",
        hash_including(type: "release", lease_id: lease.id)
      ])
    end
  end

  describe "#cancel!" do
    it "transitions to cancelled with a reason when cancellable" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input", cancellable: true)

      lease.cancel!(reason: "no longer needed")

      expect(lease.state).to eq("cancelled")
      expect(lease.cancel_reason).to eq("no longer needed")
    end

    it "raises NotCancellable when the lease was acquired as non-cancellable" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input", cancellable: false)

      expect { lease.cancel! }.to raise_error(RuntimeControlLease::NotCancellable)
      expect(lease.reload.state).to eq("active")
    end
  end

  describe "#abort! (operator abort bypasses agent cooperation)" do
    it "cancels a non-cancellable lease anyway, unlike #cancel!" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input", cancellable: false)

      lease.abort!(reason: "operator took control")

      expect(lease.state).to eq("cancelled")
      expect(lease.cancel_reason).to eq("operator took control")
    end

    it "defaults the cancel_reason when none is given" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      lease.abort!

      expect(lease.cancel_reason).to eq("aborted by operator")
    end
  end

  describe ".abort_agent_control!" do
    it "force-cancels the agent's active leases regardless of cancellable, leaving no active lease behind" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input", cancellable: false, reason: "typing")

      aborted = described_class.abort_agent_control!(runtime_session: session, reason: "user hit Abort")

      expect(aborted).to eq([ lease ])
      expect(lease.reload.state).to eq("cancelled")
      expect(session.active_agent_input_lease).to be_nil
    end

    it "does not touch a user-held lease" do
      session = build_session
      user_lease = described_class.acquire!(runtime_session: session, owner: "user", mode: "build")

      described_class.abort_agent_control!(runtime_session: session)

      expect(user_lease.reload.state).to eq("active")
    end

    it "is a no-op when the agent holds no active lease" do
      session = build_session

      expect(described_class.abort_agent_control!(runtime_session: session)).to eq([])
    end

    it "rejects a subsequent input event until a new lease is granted" do
      session = build_session
      described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      described_class.abort_agent_control!(runtime_session: session)
      expect(session.agent_input_lease_active?).to be false

      described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")
      expect(session.agent_input_lease_active?).to be true
    end
  end

  describe "#expire!" do
    it "transitions an active lease to expired" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      lease.expire!

      expect(lease.state).to eq("expired")
      expect(lease.released_at).not_to be_nil
    end

    it "is a no-op once the lease has already ended" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")
      lease.release!

      lease.expire!

      expect(lease.state).to eq("released")
    end
  end

  describe "#active?" do
    it "is false once expires_at is in the past even if state is still active" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      travel_to(lease.expires_at + 1.second) do
        expect(lease).not_to be_active
      end
    end
  end

  describe "scopes" do
    it ".active excludes time-expired rows even without an explicit expire!" do
      session = build_session
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      travel_to(lease.expires_at + 1.second) do
        expect(described_class.active).not_to include(lease)
      end
    end
  end

  describe "audit trail" do
    it "writes an acquire JobLog entry when the session is attached to a Run" do
      run = Factories.run
      session = build_session(job: run.job, workflow: run.workflow, run: run)

      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input", reason: "click")

      entry = run.reload.job_logs.order(:sequence).last
      expect(entry.kind).to eq("runtime_control_lease")
      expect(entry.chunk).to include("action=acquire", "lease=#{lease.id}", "owner=agent", "mode=input")
    end

    it "writes a release JobLog entry" do
      run = Factories.run
      session = build_session(job: run.job, workflow: run.workflow, run: run)
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      lease.release!

      expect(run.reload.job_logs.order(:sequence).last.chunk).to include("action=release")
    end

    it "writes an input JobLog entry via #record_input!" do
      run = Factories.run
      session = build_session(job: run.job, workflow: run.workflow, run: run)
      lease = described_class.acquire!(runtime_session: session, owner: "agent", mode: "input")

      lease.record_input!(type: "click", target: "#submit")

      entry = run.reload.job_logs.order(:sequence).last
      expect(entry.kind).to eq("runtime_control_lease")
      expect(entry.chunk).to include("action=input", "lease=#{lease.id}")
    end

    it "writes an input_rejected JobLog entry via .audit_input_rejected!" do
      run = Factories.run
      session = build_session(job: run.job, workflow: run.workflow, run: run)

      described_class.audit_input_rejected!(runtime_session: session, event: { type: "click" })

      entry = run.reload.job_logs.order(:sequence).last
      expect(entry.kind).to eq("runtime_control_lease")
      expect(entry.chunk).to include("action=input_rejected")
    end

    it "does not raise and writes no JobLog when the session has no Run" do
      session = build_session

      expect { described_class.acquire!(runtime_session: session, owner: "agent", mode: "input") }.not_to raise_error
      expect(JobLog.count).to eq(0)
    end
  end
end
