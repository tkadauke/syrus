require "rails_helper"

RSpec.describe Tailscale::Callbacks do
  let(:manager) { instance_double(Tailscale::DaemonManager) }

  before do
    allow(Tailscale::DaemonManager).to receive(:instance).and_return(manager)
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
    it "calls stop on the daemon manager" do
      allow(manager).to receive(:stop)
      described_class.on_disable
      expect(manager).to have_received(:stop)
    end
  end

  describe ".on_shutdown" do
    it "calls stop on the daemon manager" do
      allow(manager).to receive(:stop)
      described_class.on_shutdown
      expect(manager).to have_received(:stop)
    end
  end
end
