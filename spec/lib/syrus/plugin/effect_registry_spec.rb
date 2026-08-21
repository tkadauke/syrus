require "rails_helper"
require "syrus/plugin/effect_registry"

RSpec.describe Syrus::Plugin::EffectRegistry do
  around do |ex|
    described_class.reset!
    ex.run
    described_class.reset!
  end

  describe ".register / .drain!" do
    it "runs cleanups in LIFO order" do
      order = []
      described_class.register("my_plugin") { order << :first }
      described_class.register("my_plugin") { order << :second }
      described_class.register("my_plugin") { order << :third }

      described_class.drain!("my_plugin")

      expect(order).to eq(%i[third second first])
    end

    it "clears the stack so a second drain is a no-op" do
      calls = 0
      described_class.register("my_plugin") { calls += 1 }

      described_class.drain!("my_plugin")
      described_class.drain!("my_plugin")

      expect(calls).to eq(1)
    end

    it "does not run cleanups registered for a different plugin" do
      other_ran = false
      described_class.register("other_plugin") { other_ran = true }

      described_class.drain!("my_plugin")

      expect(other_ran).to be(false)
    end

    it "rescues and logs a raising cleanup without blocking later cleanups" do
      order = []
      allow(Rails.logger).to receive(:warn)

      described_class.register("my_plugin") { order << :first }
      described_class.register("my_plugin") { raise "boom" }
      described_class.register("my_plugin") { order << :third }

      described_class.drain!("my_plugin")

      expect(order).to eq(%i[third first])
      expect(Rails.logger).to have_received(:warn).with(/cleanup failed for my_plugin/)
    end

    it "accepts symbol and string plugin names interchangeably" do
      calls = 0
      described_class.register(:my_plugin) { calls += 1 }

      described_class.drain!("my_plugin")

      expect(calls).to eq(1)
    end

    it "is a no-op when nothing was registered for the plugin" do
      expect { described_class.drain!("never_registered") }.not_to raise_error
    end

    it "raises ArgumentError when register is called without a block" do
      expect { described_class.register("my_plugin") }.to raise_error(ArgumentError)
    end
  end
end
