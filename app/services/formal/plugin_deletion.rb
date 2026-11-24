module Formal
  # Decides whether deleting a bundled plugin leaves a closed system, from the
  # dependency facts the source boundary audit already extracts, instead of
  # booting a reduced copy of the tree (bin/plugin-boundary-audit).
  #
  # The rule is formal/SyrusModel/PluginDeletion.lean's `decide_with_unknowns`:
  # deleting a plugin removes it and every plugin that depends on it; the rest
  # is closed when no edge leaves a kept node into the removed set
  # (`closed_of_no_crossing`). An edge the extractor cannot resolve makes the
  # verdict `needs_run`, which falls back to the real deletion run.
  # spec/formal/plugin_deletion_conformance_spec.rb checks `verdict` against the
  # model on every small graph.
  class PluginDeletion
    CORE = :core

    Edge = Data.define(:from, :to, :kind, :evidence)
    Facts = Data.define(:plugin, :removed, :edges, :unknown_from)
    Result = Data.define(:plugin, :removed, :verdict, :crossing, :unknown)

    # owner: node -> CORE or a plugin name. edges: [[from, to], ...].
    # unknown_from: nodes with an edge the extractor could not resolve.
    def self.verdict(owner:, edges:, removed:, unknown_from: [])
      removed = removed.to_set
      gone = ->(node) { owner.fetch(node) != CORE && removed.include?(owner.fetch(node)) }
      return :broken if edges.any? { |from, to| !gone.call(from) && gone.call(to) }
      return :needs_run if unknown_from.any? { |node| !gone.call(node) }

      :safe
    end

    def self.call(plugin, audit: Admin::PluginSourceBoundaryAudit.new)
      new(audit).call(plugin)
    end

    def initialize(audit)
      @audit = audit
    end

    def call(plugin)
      facts = facts_for(plugin)
      owner = Hash.new { |hash, node| hash[node] = owner_of(node) }
      facts.edges.each { |edge| owner[edge.from]; owner[edge.to] }
      facts.unknown_from.each { |node| owner[node] }
      verdict = self.class.verdict(owner: owner, edges: facts.edges.map { |edge| [ edge.from, edge.to ] },
        removed: facts.removed, unknown_from: facts.unknown_from)
      crossing = facts.edges.select { |edge| owner[edge.from] == CORE || !facts.removed.include?(owner[edge.from]) }
        .select { |edge| facts.removed.include?(owner[edge.to]) }
      Result.new(plugin: plugin, removed: facts.removed, verdict: verdict, crossing: crossing, unknown: facts.unknown_from)
    end

    # Each audit violation is an edge from the referring file to the plugin it
    # names (that plugin's node is the plugin itself). Core references, and
    # undeclared plugin-to-plugin references, are both edges the deletion run
    # would trip over.
    def facts_for(plugin)
      removed = @audit.removed_plugin_names_for(plugin)
      Facts.new(plugin: plugin, removed: removed, edges: edges, unknown_from: [])
    end

    # One source scan serves every plugin's verdict.
    def edges
      @edges ||= (@audit.core_violations + @audit.plugin_violations).map do |violation|
        Edge.new(from: violation.path, to: "plugin:#{violation.target}", kind: violation.reason, evidence: violation.evidence)
      end
    end

    private

    def owner_of(node)
      return node.delete_prefix("plugin:") if node.start_with?("plugin:")

      match = node.match(%r{\Aplugins/([^/]+)/})
      return CORE unless match

      dir = match[1]
      @audit.bundled_manifests.find { |manifest| manifest.path.to_s.end_with?("plugins/#{dir}") }&.name || dir
    end
  end
end
