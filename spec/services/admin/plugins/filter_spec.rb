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
