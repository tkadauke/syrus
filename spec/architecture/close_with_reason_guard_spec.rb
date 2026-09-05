require "rails_helper"
require "prism"

# CLAUDE.md documents "always call `may_X?` before `state_X!`" as a hard
# convention (see the AASM event guards note), added after a past production
# incident (commit 7fb6aae). `Job#close_with_reason!` sets `closure_reason`
# and then calls the AASM `close!` event, which silently no-ops on a
# rejected transition (`whiny_transitions: false`). A `close_with_reason!`
# call that isn't preceded by a `may_close?` check can therefore leave
# `closure_reason` set on a Job that never actually closed.
#
# This scans the Steps:: handlers -- where this class of bug was found
# (inconsistent `job.open?` guards, and a few call sites with no guard at
# all) -- and fails if any method calls `close_with_reason!` without an
# earlier call to `may_close?` in the same method body.
RSpec.describe "close_with_reason! call sites are guarded by may_close?" do
  CLOSE_GUARD_SOURCES = Dir[Rails.root.join("app/services/steps/**/*.rb")] +
            Dir[Rails.root.join("plugins/*/app/services/steps/**/*.rb")]

  GUARDED_CALL = "close_with_reason!".freeze
  GUARD = "may_close?".freeze

  def self.collect_calls(node, list)
    return unless node.is_a?(Prism::Node)

    list << { name: node.name.to_s, line: node.location.start_line } if node.is_a?(Prism::CallNode)
    node.compact_child_nodes.each { |child| collect_calls(child, list) }
  end

  def self.collect_defs(node, list)
    return unless node.is_a?(Prism::Node)

    list << node if node.is_a?(Prism::DefNode)
    node.compact_child_nodes.each { |child| collect_defs(child, list) }
  end

  # Every `def` (across all Steps:: sources) whose body calls
  # close_with_reason!, alongside the ordered list of calls in that body.
  def self.methods_calling_close_with_reason
    CLOSE_GUARD_SOURCES.flat_map do |path|
      tree = Prism.parse(File.read(path)).value
      defs = []
      collect_defs(tree, defs)

      defs.filter_map do |def_node|
        next unless def_node.body

        calls = []
        collect_calls(def_node.body, calls)
        next unless calls.any? { |c| c[:name] == GUARDED_CALL }

        { path: Pathname(path).relative_path_from(Rails.root).to_s, method: def_node.name, calls: calls }
      end
    end
  end

  it "guards every close_with_reason! call with an earlier may_close? check in the same method" do
    unguarded = self.class.methods_calling_close_with_reason.filter_map do |entry|
      first_guard_line = entry[:calls].find { |c| c[:name] == GUARD }&.fetch(:line)
      call_lines = entry[:calls].select { |c| c[:name] == GUARDED_CALL }.map { |c| c[:line] }

      unguarded_lines = if first_guard_line
        call_lines.select { |line| line < first_guard_line }
      else
        call_lines
      end

      next if unguarded_lines.empty?

      "#{entry[:path]}##{entry[:method]} (line #{unguarded_lines.min}): close_with_reason! called without a preceding may_close? guard"
    end

    expect(unguarded).to be_empty, "found close_with_reason! call sites without a may_close? guard:\n  #{unguarded.join("\n  ")}"
  end

  it "actually finds close_with_reason! call sites, so a rename cannot quietly empty this check" do
    expect(self.class.methods_calling_close_with_reason).not_to be_empty
  end
end
