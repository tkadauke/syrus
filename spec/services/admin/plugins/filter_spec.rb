require "rails_helper"

RSpec.describe Admin::Plugins::Filter do
  after { Syrus::PluginRegistry.reset! }

  def filter_for(tree)
    described_class.from_params({ Filters::QueryParam::PARAM_NAME => Filters::QueryParam.encode(tree) })
  end

  # Real bundled plugins (admin_mysql, git_history, spending_insights, ...)
  # stay registered across the suite, so scope every scope down to the
  # test's own plugin names first — mirrors how Admin::PluginsPayload
  # always intersects against the manifests it already knows about rather
  # than querying PluginRecord.all unscoped.
  def scope_for(*names)
    PluginRecord.where(name: names)
  end

  it "filters by the enabled chip" do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(name: "enabled-plugin", version: "1.0.0")
    Syrus::PluginRegistry.register(name: "disabled-plugin", version: "1.0.0")
    PluginRecord.find_by!(name: "disabled-plugin").update!(enabled: false)

    tree = { "and" => [ { "field" => "enabled", "op" => "is", "value" => "disabled" } ] }

    scope = scope_for("enabled-plugin", "disabled-plugin")
    expect(filter_for(tree).apply(scope).pluck(:name)).to eq([ "disabled-plugin" ])
  end

  it "filters by the author chip" do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(name: "ada-plugin", version: "1.0.0", author: "Ada Lovelace")
    Syrus::PluginRegistry.register(name: "grace-plugin", version: "1.0.0", author: "Grace Hopper")

    tree = { "and" => [ { "field" => "author", "op" => "contains", "value" => "Ada" } ] }

    scope = scope_for("ada-plugin", "grace-plugin")
    expect(filter_for(tree).apply(scope).pluck(:name)).to eq([ "ada-plugin" ])
  end

  it "filters by the extension point chip" do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "agent-plugin",
      version: "1.0.0",
      provides: { agent_provider: AdminPluginsFilterSpec::Provider }
    )
    Syrus::PluginRegistry.register(
      name: "input-plugin",
      version: "1.0.0",
      provides: { input_source: AdminPluginsFilterSpec::InputSource }
    )

    tree = { "and" => [ { "field" => "extension_point", "op" => "is", "value" => "agent_provider" } ] }

    scope = scope_for("agent-plugin", "input-plugin")
    expect(filter_for(tree).apply(scope).pluck(:name)).to eq([ "agent-plugin" ])
  end

  it "finds plugins without extension points with is_unset" do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "provider-plugin",
      version: "1.0.0",
      provides: { agent_provider: AdminPluginsFilterSpec::Provider }
    )
    Syrus::PluginRegistry.register(name: "metadata-only-plugin", version: "1.0.0")

    tree = { "and" => [ { "field" => "extension_point", "op" => "is_unset" } ] }

    scope = scope_for("provider-plugin", "metadata-only-plugin")
    expect(filter_for(tree).apply(scope).pluck(:name)).to eq([ "metadata-only-plugin" ])
  end

  it "filters by the category chip" do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(name: "observability-plugin", version: "1.0.0", category: "observability")
    Syrus::PluginRegistry.register(name: "connectivity-plugin", version: "1.0.0", category: "connectivity")

    tree = { "and" => [ { "field" => "category", "op" => "is", "value" => "observability" } ] }

    scope = scope_for("observability-plugin", "connectivity-plugin")
    expect(filter_for(tree).apply(scope).pluck(:name)).to eq([ "observability-plugin" ])
  end

  it "filters by the category chip with is_one_of" do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(name: "observability-plugin", version: "1.0.0", category: "observability")
    Syrus::PluginRegistry.register(name: "connectivity-plugin", version: "1.0.0", category: "connectivity")
    Syrus::PluginRegistry.register(name: "tooling-plugin", version: "1.0.0", category: "tooling")

    tree = { "and" => [ { "field" => "category", "op" => "is_one_of", "value" => %w[observability connectivity] } ] }

    scope = scope_for("observability-plugin", "connectivity-plugin", "tooling-plugin")
    expect(filter_for(tree).apply(scope).pluck(:name)).to contain_exactly("observability-plugin", "connectivity-plugin")
  end

  it "finds uncategorized plugins with is_unset" do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(name: "categorized-plugin", version: "1.0.0", category: "observability")
    Syrus::PluginRegistry.register(name: "uncategorized-plugin", version: "1.0.0")

    tree = { "and" => [ { "field" => "category", "op" => "is_unset" } ] }

    scope = scope_for("categorized-plugin", "uncategorized-plugin")
    expect(filter_for(tree).apply(scope).pluck(:name)).to eq([ "uncategorized-plugin" ])
  end

  it "filters by the search chip across name, display_name, description, and category" do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "search-target-plugin",
      display_name: "Weather Radar",
      version: "1.0.0",
      description: "Watches storms roll in."
    )
    Syrus::PluginRegistry.register(name: "search-other-plugin", version: "1.0.0", description: "Keeps issues in sync.")

    tree = { "and" => [ { "field" => "search", "op" => "contains", "value" => "storms" } ] }

    scope = scope_for("search-target-plugin", "search-other-plugin")
    expect(filter_for(tree).apply(scope).pluck(:name)).to eq([ "search-target-plugin" ])
  end

  it "combines category and search chips with AND semantics" do
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(name: "both-match-plugin", version: "1.0.0", category: "observability", description: "Watches storms roll in.")
    Syrus::PluginRegistry.register(name: "category-only-plugin", version: "1.0.0", category: "observability", description: "Nothing weather related here.")

    tree = {
      "and" => [
        { "field" => "category", "op" => "is", "value" => "observability" },
        { "field" => "search", "op" => "contains", "value" => "storms" }
      ]
    }

    scope = scope_for("both-match-plugin", "category-only-plugin")
    expect(filter_for(tree).apply(scope).pluck(:name)).to eq([ "both-match-plugin" ])
  end

  it "is inactive with no filter applied" do
    filter = described_class.from_params({})

    expect(filter.active?).to be(false)
    expect(filter.to_h).to eq("and" => [])
  end
end

module AdminPluginsFilterSpec
  class Provider
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "admin_plugins_filter_spec"
    def self.display_name = "Admin plugins filter spec"
    def self.name = "AdminPluginsFilterSpec::Provider"
    def self.available? = true
  end

  class InputSource < ::InputSource
    include Syrus::Plugin::InputSource

    def self.name = "AdminPluginsFilterSpec::InputSource"
    def self.detect?(_repository) = false
  end
end
