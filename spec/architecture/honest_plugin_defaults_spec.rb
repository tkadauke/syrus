require "rails_helper"

RSpec.describe "fresh-install plugin defaults" do
  it "keeps experimental plugin and feature declarations default-disabled" do
    experimental_plugins = Syrus::PluginRegistry.all_plugins.select(&:experimental?)
    experimental_features = FeatureRegistry.declarations.select(&:experimental)

    expect(experimental_plugins).to all(satisfy { |plugin| !plugin.default_enabled? })
    expect(experimental_features).to all(satisfy { |feature| !feature.default_enabled })
  end

  it "does not report opt-in or unavailable capabilities enabled in a blank database" do
    AppSetting.current.update!(beta_mode_enabled: false)
    PluginRecord.delete_all
    Syrus::PluginRegistry.clear_plugin_record_cache!

    plugins = Syrus::PluginRegistry.all_plugins.index_by(&:name)
    opt_in_plugins = %w[build_cache design_docs spending_insights team_directory credential_store git_history]

    expect(plugins.values.select(&:experimental?)).to all(satisfy { |plugin| !plugin.enabled? })
    expect(plugins.values_at(*opt_in_plugins)).to all(satisfy { |plugin| !plugin.enabled? })
  end
end
