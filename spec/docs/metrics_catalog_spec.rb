require "rails_helper"

RSpec.describe "Metrics catalog" do
  # Metrics are declared in class bodies, so the registry holds only what has
  # been autoloaded. Without eager loading these examples pass or fail by
  # whatever earlier specs happened to reference -- which is how a metric
  # stayed missing from the committed catalog while this spec was green in
  # isolation and red in a full run.
  before { Rails.application.eager_load! }

  # Distributed declaration means there is no single file listing the metrics,
  # so the list is generated instead of maintained. A generated list nobody
  # regenerates is worse than none, which is what this guards.
  it "matches the registry" do
    expect(Syrus::Metrics::Catalog.committed).to eq(Syrus::Metrics::Catalog.render),
      "docs/metrics-catalog.md is out of date. Run bin/metrics-catalog."
  end

  # Enumerating plugin-owned metrics in a core document would make those plugins
  # undeletable: removing one would change a core file and fail
  # bin/plugin-boundary-audit. Plugin metrics are namespaced syrus_<plugin>_*
  # and belong in the owning plugin's own docs.
  it "lists core metrics only" do
    catalog = Syrus::Metrics::Catalog.committed.to_s
    plugin_metrics = Syrus::Metrics.definitions.reject(&:core?)

    plugin_metrics.each do |definition|
      expect(catalog).not_to include(definition.name.to_s)
    end
  end

  it "documents every core metric that is declared" do
    catalog = Syrus::Metrics::Catalog.committed.to_s

    Syrus::Metrics.definitions.select(&:core?).each do |definition|
      expect(catalog).to include("`#{definition.name}`")
    end
  end
end
