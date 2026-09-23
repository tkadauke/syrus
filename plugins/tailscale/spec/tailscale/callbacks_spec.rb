require "rails_helper"

RSpec.describe Tailscale::Callbacks do
  before do
    Syrus::Plugin::EffectRegistry.drain!("tailscale")
    allow(Tailscale::HostAllowlist).to receive(:sync)
    allow(Tailscale::HostAllowlist).to receive(:clear)
  end

  after { Syrus::Plugin::EffectRegistry.drain!("tailscale") }

  def stub_available(available)
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("tailscale")
      .and_return(available ? "http://tailscale:8080" : nil)
  end

  shared_examples "syncs the host allowlist when the container is available" do |method|
    context "when the tailscale-service container is available" do
      before { stub_available(true) }

      it "syncs the host allowlist" do
        described_class.public_send(method)
        expect(Tailscale::HostAllowlist).to have_received(:sync)
      end

      it "registers an effect that clears the host allowlist on drain" do
        described_class.public_send(method)

        Syrus::Plugin::EffectRegistry.drain!("tailscale")

        expect(Tailscale::HostAllowlist).to have_received(:clear)
      end

      it "does not clear the host allowlist before the effect is drained" do
        described_class.public_send(method)
        expect(Tailscale::HostAllowlist).not_to have_received(:clear)
      end
    end

    context "when the tailscale-service container is not available" do
      before { stub_available(false) }

      it "does not sync the host allowlist" do
        described_class.public_send(method)
        expect(Tailscale::HostAllowlist).not_to have_received(:sync)
      end

      it "does not register a host allowlist cleanup effect" do
        described_class.public_send(method)

        Syrus::Plugin::EffectRegistry.drain!("tailscale")

        expect(Tailscale::HostAllowlist).not_to have_received(:clear)
      end
    end
  end

  describe ".on_boot" do
    include_examples "syncs the host allowlist when the container is available", :on_boot
  end

  describe ".on_enable" do
    include_examples "syncs the host allowlist when the container is available", :on_enable
  end

  describe ".on_tick" do
    context "when the tailscale-service container is available" do
      before { stub_available(true) }

      it "syncs the host allowlist" do
        described_class.on_tick
        expect(Tailscale::HostAllowlist).to have_received(:sync)
      end
    end

    context "when the tailscale-service container is not available" do
      before { stub_available(false) }

      it "does not sync the host allowlist" do
        described_class.on_tick
        expect(Tailscale::HostAllowlist).not_to have_received(:sync)
      end
    end
  end

  describe "drain via PluginLifecycleJob" do
    before { stub_available(true) }

    it "clears the host allowlist when the plugin is disabled" do
      described_class.on_enable

      PluginLifecycleJob.perform_now("tailscale", "on_disable")

      expect(Tailscale::HostAllowlist).to have_received(:clear)
    end
  end
end
