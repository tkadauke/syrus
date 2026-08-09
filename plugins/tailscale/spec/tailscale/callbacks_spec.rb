require "rails_helper"

RSpec.describe Tailscale::Callbacks do
  let(:manager) { instance_double(Tailscale::DaemonManager) }

  before do
    allow(Tailscale::DaemonManager).to receive(:instance).and_return(manager)
    allow(manager).to receive(:alive?).and_return(false)
    allow(Tailscale::HostAllowlist).to receive(:sync)
    allow(Tailscale::HostAllowlist).to receive(:clear)
  end

  describe ".on_boot" do
    context "when TS_AUTHKEY is present" do
      before { allow(ENV).to receive(:[]).and_call_original }
      before { allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return("tskey-auth-abc123") }

      it "calls start on the daemon manager" do
        allow(manager).to receive(:start)
        described_class.on_boot
        expect(manager).to have_received(:start)
      end

      context "when daemon is alive after start" do
        before do
          allow(manager).to receive(:start)
          allow(manager).to receive(:alive?).and_return(true)
        end

        it "syncs the host allowlist" do
          described_class.on_boot
          expect(Tailscale::HostAllowlist).to have_received(:sync)
        end
      end

      context "when daemon is not alive after start" do
        before do
          allow(manager).to receive(:start)
          allow(manager).to receive(:alive?).and_return(false)
        end

        it "does not sync the host allowlist" do
          described_class.on_boot
          expect(Tailscale::HostAllowlist).not_to have_received(:sync)
        end
      end
    end

    context "when TS_AUTHKEY is absent" do
      before { allow(ENV).to receive(:[]).and_call_original }
      before { allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return(nil) }

      it "does not call start" do
        allow(manager).to receive(:start)
        described_class.on_boot
        expect(manager).not_to have_received(:start)
      end
    end
  end

  describe ".on_enable" do
    context "when TS_AUTHKEY is present" do
      before { allow(ENV).to receive(:[]).and_call_original }
      before { allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return("tskey-auth-abc123") }

      it "calls start on the daemon manager" do
        allow(manager).to receive(:start)
        described_class.on_enable
        expect(manager).to have_received(:start)
      end

      context "when daemon is alive after start" do
        before do
          allow(manager).to receive(:start)
          allow(manager).to receive(:alive?).and_return(true)
        end

        it "syncs the host allowlist" do
          described_class.on_enable
          expect(Tailscale::HostAllowlist).to have_received(:sync)
        end
      end
    end

    context "when TS_AUTHKEY is absent" do
      before { allow(ENV).to receive(:[]).and_call_original }
      before { allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return(nil) }

      it "does not call start" do
        allow(manager).to receive(:start)
        described_class.on_enable
        expect(manager).not_to have_received(:start)
      end
    end
  end

  describe ".on_tick" do
    context "when TS_AUTHKEY is present" do
      before { allow(ENV).to receive(:[]).and_call_original }
      before { allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return("tskey-auth-abc123") }

      it "calls restart_if_dead on the daemon manager" do
        allow(manager).to receive(:restart_if_dead)
        described_class.on_tick
        expect(manager).to have_received(:restart_if_dead)
      end

      context "when daemon is alive" do
        before do
          allow(manager).to receive(:restart_if_dead)
          allow(manager).to receive(:alive?).and_return(true)
        end

        it "syncs the host allowlist" do
          described_class.on_tick
          expect(Tailscale::HostAllowlist).to have_received(:sync)
        end
      end

      context "when daemon is not alive" do
        before do
          allow(manager).to receive(:restart_if_dead)
          allow(manager).to receive(:alive?).and_return(false)
        end

        it "does not sync the host allowlist" do
          described_class.on_tick
          expect(Tailscale::HostAllowlist).not_to have_received(:sync)
        end
      end
    end

    context "when TS_AUTHKEY is absent" do
      before { allow(ENV).to receive(:[]).and_call_original }
      before { allow(ENV).to receive(:[]).with("TS_AUTHKEY").and_return(nil) }

      it "does not call restart_if_dead" do
        allow(manager).to receive(:restart_if_dead)
        described_class.on_tick
        expect(manager).not_to have_received(:restart_if_dead)
      end
    end
  end

  describe ".on_disable" do
    before { allow(manager).to receive(:stop) }

    it "clears the host allowlist" do
      described_class.on_disable
      expect(Tailscale::HostAllowlist).to have_received(:clear)
    end

    it "calls stop on the daemon manager" do
      described_class.on_disable
      expect(manager).to have_received(:stop)
    end

    it "clears the allowlist before stopping the daemon" do
      clear_order = []
      allow(Tailscale::HostAllowlist).to receive(:clear) { clear_order << :clear }
      allow(manager).to receive(:stop) { clear_order << :stop }
      described_class.on_disable
      expect(clear_order).to eq([:clear, :stop])
    end
  end

  describe ".on_shutdown" do
    before { allow(manager).to receive(:stop) }

    it "clears the host allowlist" do
      described_class.on_shutdown
      expect(Tailscale::HostAllowlist).to have_received(:clear)
    end

    it "calls stop on the daemon manager" do
      described_class.on_shutdown
      expect(manager).to have_received(:stop)
    end
  end
end
