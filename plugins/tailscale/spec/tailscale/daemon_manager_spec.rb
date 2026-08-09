require "rails_helper"

RSpec.describe Tailscale::DaemonManager do
  subject(:manager) { described_class.instance }

  before do
    manager.instance_variable_set(:@pid, nil)
    allow(manager).to receive(:worker_context?).and_return(true)
  end

  describe "#start" do
    before do
      allow(Process).to receive(:spawn).and_return(42)
      allow(Process).to receive(:detach)
      allow(manager).to receive(:wait_until_ready!)
      allow(manager).to receive(:run_tailscale_up!)
      allow(manager).to receive(:run_tailscale_serve!)
    end

    it "spawns tailscaled with state and socket paths" do
      manager.start

      expect(Process).to have_received(:spawn).with(
        "tailscaled",
        "--state=#{Tailscale::DaemonManager::STATE_PATH}",
        "--socket=#{Tailscale::DaemonManager::SOCKET_PATH}",
        out: File::NULL,
        err: File::NULL
      )
    end

    it "detaches the spawned process" do
      manager.start
      expect(Process).to have_received(:detach).with(42)
    end

    it "waits for daemon readiness then runs up and serve" do
      manager.start

      expect(manager).to have_received(:wait_until_ready!).ordered
      expect(manager).to have_received(:run_tailscale_up!).ordered
      expect(manager).to have_received(:run_tailscale_serve!).ordered
    end

    it "stores the spawned PID" do
      manager.start
      expect(manager.instance_variable_get(:@pid)).to eq(42)
    end

    context "when already alive" do
      before { manager.instance_variable_set(:@pid, 99) }

      it "does not spawn a second process" do
        allow(manager).to receive(:alive?).and_return(true)
        manager.start
        expect(Process).not_to have_received(:spawn)
      end
    end

    context "when not in worker context" do
      before { allow(manager).to receive(:worker_context?).and_return(false) }

      it "does not spawn tailscaled" do
        manager.start
        expect(Process).not_to have_received(:spawn)
      end
    end
  end

  describe "#alive?" do
    context "when @pid is nil" do
      it "returns false" do
        expect(manager.alive?).to be(false)
      end
    end

    context "when @pid references a live process" do
      before do
        manager.instance_variable_set(:@pid, 123)
        allow(Process).to receive(:kill).with(0, 123).and_return(1)
      end

      it "returns true" do
        expect(manager.alive?).to be(true)
      end
    end

    context "when @pid references a dead process" do
      before do
        manager.instance_variable_set(:@pid, 123)
        allow(Process).to receive(:kill).with(0, 123).and_raise(Errno::ESRCH)
      end

      it "returns false" do
        expect(manager.alive?).to be(false)
      end
    end
  end

  describe "#restart_if_dead" do
    it "calls start when not alive" do
      allow(manager).to receive(:alive?).and_return(false)
      allow(manager).to receive(:start)

      manager.restart_if_dead

      expect(manager).to have_received(:start)
    end

    it "does not call start when alive" do
      allow(manager).to receive(:alive?).and_return(true)
      allow(manager).to receive(:start)

      manager.restart_if_dead

      expect(manager).not_to have_received(:start)
    end
  end

  describe "#stop" do
    before do
      manager.instance_variable_set(:@pid, 55)
      allow(manager).to receive(:run_tailscale_logout)
      allow(Process).to receive(:kill)
    end

    it "runs tailscale logout" do
      manager.stop
      expect(manager).to have_received(:run_tailscale_logout)
    end

    it "sends TERM to the tailscaled process" do
      manager.stop
      expect(Process).to have_received(:kill).with("TERM", 55)
    end

    it "clears the stored PID" do
      manager.stop
      expect(manager.instance_variable_get(:@pid)).to be_nil
    end

    context "when the process is already gone" do
      before { allow(Process).to receive(:kill).and_raise(Errno::ESRCH) }

      it "does not raise" do
        expect { manager.stop }.not_to raise_error
      end
    end

    context "when logout raises" do
      before { allow(manager).to receive(:run_tailscale_logout).and_raise("logout failed") }

      it "still sends TERM and clears the PID" do
        manager.stop
        expect(Process).to have_received(:kill).with("TERM", 55)
        expect(manager.instance_variable_get(:@pid)).to be_nil
      end
    end

    context "when @pid is nil" do
      before { manager.instance_variable_set(:@pid, nil) }

      it "does not call Process.kill" do
        manager.stop
        expect(Process).not_to have_received(:kill)
      end
    end
  end
end
