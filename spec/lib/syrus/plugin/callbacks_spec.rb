require "rails_helper"
require "syrus/plugin/callbacks"
require "syrus/plugin/effect_registry"

RSpec.describe Syrus::Plugin::Callbacks do
  describe "interface defaults" do
    let(:concrete_class) { Class.new { include Syrus::Plugin::Callbacks } }

    it "defaults every lifecycle method to nil" do
      expect(concrete_class.on_boot).to be_nil
      expect(concrete_class.on_shutdown).to be_nil
      expect(concrete_class.on_enable).to be_nil
      expect(concrete_class.on_disable).to be_nil
      expect(concrete_class.on_tick).to be_nil
    end
  end

  describe ".effect", :reset_plugin_registry do
    around do |ex|
      Syrus::PluginRegistry.reset!
      Syrus::Plugin::EffectRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
      Syrus::Plugin::EffectRegistry.reset!
    end

    let(:callbacks_class) { Class.new { include Syrus::Plugin::Callbacks } }

    context "when the including class is registered as a plugin's callbacks provider" do
      before do
        Syrus::PluginRegistry.register(
          name: "effect_plugin",
          version: "1.0.0",
          provides: { callbacks: callbacks_class }
        )
      end

      it "registers the cleanup under the resolved plugin name" do
        ran = false
        callbacks_class.effect { ran = true }

        Syrus::Plugin::EffectRegistry.drain!("effect_plugin")

        expect(ran).to be(true)
      end

      it "does not run the cleanup immediately" do
        ran = false
        callbacks_class.effect { ran = true }

        expect(ran).to be(false)
      end
    end

    context "when the including class is not registered with any plugin" do
      it "raises instead of silently dropping the cleanup" do
        expect { callbacks_class.effect { nil } }.to raise_error(/Unable to resolve plugin name/)
      end
    end
  end
end
