require "rails_helper"
require "prism"

# An unreadable plugin_records table must never read as "every installed
# plugin is on": that can switch on a plugin the operator disabled, an
# execution backend or an approval provider among them. PluginRegistry
# answers that through #enablement_records, which uses the declared defaults
# before the table exists and otherwise retries and raises
# (formal/SyrusModel/EnablementRead.lean).
#
# The behavioural specs pin the methods that exist today. This pins the shape
# for the ones added later: no PluginRegistry method that decides enablement
# (calls plugin_enabled?) may rescue a database error itself, because the
# rescue body is where "fall back to every plugin" goes.
RSpec.describe "PluginRegistry enablement reads fail closed" do
  # Fails *open* in the safe direction: an unreadable table skips nothing, so
  # every plugin's code is eager-loaded and nothing is switched on.
  FAIL_SAFE_RESCUES = %w[eager_load_skippable_plugin_names].freeze
  DATABASE_ERRORS = %w[ActiveRecord::ActiveRecordError StandardError ActiveRecord::StatementInvalid].freeze

  def calls?(node, name)
    return false unless node.is_a?(Prism::Node)
    return true if node.is_a?(Prism::CallNode) && node.name == name

    node.compact_child_nodes.any? { |child| calls?(child, name) }
  end

  def rescued_database_errors(node, found = [])
    return found unless node.is_a?(Prism::Node)

    if node.is_a?(Prism::RescueNode)
      names = node.exceptions.map(&:slice)
      found.concat(names.empty? ? [ "StandardError" ] : names & DATABASE_ERRORS)
    end
    node.compact_child_nodes.each { |child| rescued_database_errors(child, found) }
    found
  end

  it "has no enablement-deciding method that rescues a database error itself" do
    source = Rails.root.join("lib/syrus/plugin_registry.rb")
    defs = []
    walk = lambda do |node|
      next unless node.is_a?(Prism::Node)

      defs << node if node.is_a?(Prism::DefNode)
      node.compact_child_nodes.each(&walk)
    end
    walk.call(Prism.parse_file(source.to_s).value)

    offenders = defs.filter_map do |definition|
      next if FAIL_SAFE_RESCUES.include?(definition.name.to_s)
      next unless calls?(definition, :plugin_enabled?)

      rescued = rescued_database_errors(definition)
      "#{definition.name} (line #{definition.location.start_line}) rescues #{rescued.uniq.join(', ')}" if rescued.any?
    end

    expect(defs.map { |d| d.name.to_s }).to include("available_capability_plugins", "providers_for")
    expect(offenders).to be_empty,
      "read plugin enablement through enablement_records instead of rescuing:\n#{offenders.join("\n")}"
  end
end
