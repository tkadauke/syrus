require "rails_helper"

RSpec.describe "Lifecycle and DataPolicy hook families", :reset_plugin_registry do
  before do
    Syrus::Plugin::Lifecycle.restore_definition!
    Syrus::Plugin::DataPolicy.restore_definition!
  end

  def register_family(name, family, capability, behavior = nil, &selector)
    behavior ||= selector
    provider = Class.new do
      define_singleton_method(:key) { name }
      define_singleton_method(:display_name) { name }
      define_singleton_method(capability, &behavior)
    end
    constant = "#{name.camelize}#{family.to_s.camelize}"
    stub_const(constant, provider)
    Syrus::PluginRegistry.register(name:, version: "1", provides: {}, family_provides: [
      Syrus::Plugin::FamilyDeclaration.build(family:, provider: constant, provisional: [ capability ])
    ])
  end

  describe "family definitions" do
    it "maps every absorbed legacy point to a provisional collect capability" do
      expect(Syrus::Plugin::Family.fetch(:lifecycle).legacy_mappings.keys)
        .to contain_exactly(:callbacks, :domain_subscriber)
      expect(Syrus::Plugin::Family.fetch(:data_policy).legacy_mappings.keys)
        .to contain_exactly(:retention_policy, :purge_contributor, :preview_panel_retention)
      (Syrus::Plugin::Family.fetch(:lifecycle).capabilities.values + Syrus::Plugin::Family.fetch(:data_policy).capabilities.values).each do |capability|
        expect(capability).to have_attributes(composition: :collect, tier: :provisional, decline: nil)
      end
    end

    it "reports a failing retention or purge selector instead of dropping it, but lets preview retention decline" do
      data_policy = Syrus::Plugin::Family.fetch(:data_policy).capabilities
      expect(data_policy[:retention_policies].failure.call).to eq([ Syrus::Plugin::DataPolicy::UNAVAILABLE ])
      expect(data_policy[:purge_contributors].failure.call).to eq([ Syrus::Plugin::DataPolicy::UNAVAILABLE ])
      expect(data_policy[:preview_panel_retentions].failure).to be_nil
    end
  end

  describe "the legacy bridge" do
    let(:callbacks) { Class.new { include Syrus::Plugin::Callbacks } }
    let(:family_callbacks) { Class.new { include Syrus::Plugin::Callbacks } }

    it "returns legacy and family callbacks together, in one call, without core merging them" do
      stub_const("FamilyCallbacksFixture", family_callbacks)
      register_family("family_hooks", :lifecycle, :callback_providers) { |_ctx| FamilyCallbacksFixture }
      Syrus::PluginRegistry.register(name: "legacy_hooks", version: "1", provides: { callbacks: callbacks })

      expect(Syrus::Plugin::Lifecycle.callback_providers).to include(callbacks, family_callbacks)
      expect(Syrus::PluginRegistry.providers_for(:callbacks)).to include(callbacks, family_callbacks)
    end

    it "resolves one manifest's callbacks even when the plugin is disabled" do
      stub_const("FamilyCallbacksFixture", family_callbacks)
      register_family("family_hooks", :lifecycle, :callback_providers) { |_ctx| FamilyCallbacksFixture }
      manifest = Syrus::PluginRegistry.all_plugins.find { |entry| entry.name == "family_hooks" }
      PluginRecord.find_or_create_by!(name: "family_hooks").update!(enabled: false)

      expect(Syrus::Plugin::Lifecycle.callback_providers).not_to include(family_callbacks)
      expect(Syrus::Plugin::Lifecycle.callback_providers_for(manifest)).to eq([ family_callbacks ])
    end

    it "names the owning plugin of a family-declared callbacks module" do
      stub_const("FamilyCallbacksFixture", family_callbacks)
      Syrus::PluginRegistry.register(name: "family_owner", version: "1", provides: {}, family_provides: [
        Syrus::Plugin::FamilyDeclaration.build(
          family: :lifecycle, provider: "FamilyOwnerLifecycle", provisional: [ :callback_providers ]
        )
      ])
      stub_const("FamilyOwnerLifecycle", Syrus::Plugin::Lifecycle.provider(
        key: "family_owner", display_name: "Family owner", callback_providers: "FamilyCallbacksFixture"
      ))

      expect(Syrus::PluginRegistry.plugin_name_for(family_callbacks)).to eq("family_owner")
    end
  end

  describe "retention policies" do
    it "keeps every healthy contributor when one contributor is broken (family and legacy)" do
      healthy = Class.new do
        include Syrus::Plugin::RetentionPolicy
        def self.retention_definitions = [ :healthy_definition ]
      end
      broken = Class.new do
        include Syrus::Plugin::RetentionPolicy
        def self.name = "BrokenFamilyRetention"
        def self.retention_definitions = raise("broken provider")
      end
      stub_const("HealthyRetention", healthy)
      stub_const("BrokenRetention", broken)
      register_family("healthy_retention", :data_policy, :retention_policies) { |_ctx| HealthyRetention }
      Syrus::PluginRegistry.register(name: "broken_retention", version: "1", provides: { retention_policy: broken })
      allow(Rails.logger).to receive(:error)

      expect(RetentionPolicyRegistry.plugin_definitions).to include(:healthy_definition)
      expect(Rails.logger).to have_received(:error).with(/BrokenFamilyRetention.*broken provider/)
    end

    it "reports a retention provider that cannot even be resolved and still returns the others" do
      healthy = Class.new do
        include Syrus::Plugin::RetentionPolicy
        def self.retention_definitions = [ :healthy_definition ]
      end
      stub_const("HealthyRetention", healthy)
      register_family("healthy_retention", :data_policy, :retention_policies) { |_ctx| HealthyRetention }
      register_family("unresolvable_retention", :data_policy, :retention_policies) { |_ctx| raise NameError, "uninitialized constant Gone" }
      allow(Rails.logger).to receive(:error)

      expect(RetentionPolicyRegistry.plugin_definitions).to include(:healthy_definition)
      expect(Rails.logger).to have_received(:error).with(/retention policy provider is unavailable/)
    end
  end

  describe "purge contributors" do
    def contributor(label, report: [], purged: nil, &failure)
      Class.new do
        include Syrus::Plugin::PurgeContributor
        define_singleton_method(:to_s) { label }
        define_singleton_method(:purge_report) { |_name| failure ? failure.call : report }
        define_singleton_method(:purge!) { |_name| failure ? failure.call : Array(purged) }
      end
    end

    it "reports and purges every contributor when one fails" do
      healthy = contributor("HealthyPurge", report: [ "volume a" ], purged: [ "volume a" ])
      broken = contributor("BrokenPurge") { raise "manager unreachable" }
      stub_const("HealthyPurge", healthy)
      stub_const("BrokenPurge", broken)
      register_family("healthy_purge", :data_policy, :purge_contributors) { |_ctx| HealthyPurge }
      Syrus::PluginRegistry.register(name: "broken_purge", version: "1", provides: { purge_contributor: broken })
      purge = Syrus::PluginPurge.new("gone_plugin")

      other_data = purge.other_data
      expect(other_data).to include("volume a")
      expect(other_data.join).to match(/BrokenPurge: could not report .*manager unreachable/)

      allow(Syrus::PluginRegistry).to receive(:registered_names).and_return([])
      removed = purge.purge!
      expect(removed).to include("volume a")
      expect(removed.join).to match(/BrokenPurge: purge failed .*manager unreachable/)
    end

    it "does not hide a contributor that could not be loaded" do
      healthy = contributor("HealthyPurge", report: [ "volume a" ], purged: [ "volume a" ])
      stub_const("HealthyPurge", healthy)
      register_family("healthy_purge", :data_policy, :purge_contributors) { |_ctx| HealthyPurge }
      register_family("unresolvable_purge", :data_policy, :purge_contributors) { |_ctx| raise NameError, "uninitialized constant Gone" }
      purge = Syrus::PluginPurge.new("gone_plugin")

      expect(purge.other_data).to include("volume a", Syrus::PluginPurge::UNAVAILABLE_LINE)
      allow(Syrus::PluginRegistry).to receive(:registered_names).and_return([])
      expect(purge.purge!).to include("volume a", Syrus::PluginPurge::UNAVAILABLE_LINE)
    end
  end

  describe "preview panel retention" do
    it "retains a panel when any enabled provider retains it, from family or legacy registrations" do
      retaining = Class.new do
        include Syrus::Plugin::PreviewPanelRetention
        def self.retained_preview_panel?(_panel) = true
      end
      stub_const("RetainingPanels", retaining)
      register_family("retaining", :data_policy, :preview_panel_retentions) { |_ctx| RetainingPanels }
      Syrus::PluginRegistry.register(name: "declining", version: "1", provides: { preview_panel_retention: Class.new { include Syrus::Plugin::PreviewPanelRetention } })

      providers = Syrus::Plugin::DataPolicy.preview_panel_retentions
      expect(providers).to include(RetainingPanels)
      expect(providers.select { |provider| provider.equal?(RetainingPanels) }.any? { |provider| provider.retained_preview_panel?(:panel) }).to be(true)
    end
  end

  describe "domain subscribers" do
    it "isolates a failing family-declared subscriber from the publisher and the other subscribers" do
      received = []
      healthy = Class.new do
        include Syrus::Plugin::DomainSubscriber
        define_singleton_method(:subscriptions) { { "job.closed" => :on_closed } }
        define_singleton_method(:on_closed) { |event| received << event.name }
      end
      broken = Class.new do
        include Syrus::Plugin::DomainSubscriber
        def self.subscriptions = { "job.closed" => :on_closed }
        def self.on_closed(_event) = raise("subscriber exploded")
      end
      stub_const("HealthySubscriber", healthy)
      stub_const("BrokenSubscriber", broken)
      register_family("broken_subscriber", :lifecycle, :domain_subscribers) { |_ctx| BrokenSubscriber }
      register_family("healthy_subscriber", :lifecycle, :domain_subscribers) { |_ctx| HealthySubscriber }
      allow(Syrus::Events).to receive(:delivery_for).and_return(:inline)

      expect { Syrus::Events.publish("job.closed", job_id: 1) }.not_to raise_error
      expect(received).to eq([ "job.closed" ])
    end
  end

  describe "installation effects" do
    it "defines plugin effects through the Lifecycle family" do
      expect(Syrus::Installer).to receive(:define).with("hooks:label", plugin: "hooks", requires: :enabled)

      Syrus::Plugin::Lifecycle.define_effect("hooks:label", plugin: "hooks", requires: :enabled) { |_scope| nil }
    end
  end
end
