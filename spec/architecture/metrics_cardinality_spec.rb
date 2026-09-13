require "rails_helper"

# The cardinality rule, enforced over whatever is actually registered.
#
# This iterates the registry rather than naming metrics, deliberately: core
# specs must not enumerate plugin-provided things, or every bundled plugin
# becomes undeletable and bin/plugin-boundary-audit fails. Asserting the
# *property* covers plugin metrics too without ever mentioning one.
RSpec.describe "Metrics cardinality" do
  it "declares only bounded labels, whoever declared them" do
    offenders = Syrus::Metrics.definitions.filter_map do |definition|
      disallowed = definition.tags.map(&:to_sym) - Syrus::Metrics::TagAllowlist::ALLOWED
      next if disallowed.empty?

      "#{definition.name} (#{definition.owner}): #{disallowed.join(', ')}"
    end

    expect(offenders).to eq([]),
      "these metrics carry labels that are not on the cardinality allowlist:\n  #{offenders.join("\n  ")}"
  end

  it "gives every metric a help string, since the catalog and dashboards render it" do
    undocumented = Syrus::Metrics.definitions.reject { |d| d.comment.present? }.map(&:name)

    expect(undocumented).to eq([])
  end

  # A metric whose name does not start with syrus_ would be indistinguishable
  # from another exporter's series once scraped into a shared Prometheus.
  it "namespaces every metric" do
    unprefixed = Syrus::Metrics.definitions.map(&:name).reject { |name| name.to_s.start_with?("syrus_") }

    expect(unprefixed).to eq([])
  end

  # Histogram buckets are the resolution of every quantile read back out, so a
  # histogram without deliberate buckets is a quantile nobody can trust.
  it "gives every histogram explicit buckets" do
    Syrus::Metrics.definitions.select { |d| d.type == :histogram }.each do |definition|
      expect(definition.buckets).to be_present, "#{definition.name} has no buckets"
    end
  end
end
