# frozen_string_literal: true

require "yaml"
require "rails_helper"

# Regression: the website build ends in `node --experimental-strip-types`,
# which needs Node 22.6+, while the deploy-website workflow still set up Node
# 20. Node rejected the flag (exit 9) on every run for four weeks, and that red
# check alone kept main's CI health broken -- which paused CI repairs and held
# landings.
RSpec.describe "GitHub Actions Node versions" do
  MINIMUM_NODE_FOR_STRIP_TYPES = 22

  def setup_node_versions(path)
    workflow = YAML.safe_load(path.read, aliases: true)
    workflow.fetch("jobs", {}).values.flat_map { |job| Array(job["steps"]) }
      .select { |step| step["uses"].to_s.start_with?("actions/setup-node@") }
      .map { |step| step.dig("with", "node-version") }
  end

  def runs_strip_types?(path)
    commands = path.read
    commands.include?("--experimental-strip-types") ||
      commands.match?(/npm run (build|test:locales)/) && Rails.root.join("website/package.json").read.include?("--experimental-strip-types")
  end

  it "sets up a Node that supports --experimental-strip-types wherever a workflow runs a script that uses it" do
    offenders = Dir[Rails.root.join(".github/workflows/*.yml")].map { |file| Pathname(file) }.select { |path| runs_strip_types?(path) }
      .flat_map { |path| setup_node_versions(path).reject { |version| version.to_s.to_i >= MINIMUM_NODE_FOR_STRIP_TYPES }.map { |version| "#{path.basename}: node #{version}" } }

    expect(offenders).to be_empty
  end
end
