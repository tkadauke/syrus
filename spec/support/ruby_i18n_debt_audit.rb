require "prism"

class RubyI18nDebtAudit
  Finding = Data.define(:category, :path, :line, :text)

  ROOTS = %w[app plugins].freeze
  EXCLUDED_PATHS = %r{/(?:spec|test|log|vendor)/|/db/|/config/}.freeze
  CATEGORIES = %i[render_error response_field model_error serializer_label].freeze
  RESPONSE_KEYS = %w[message notice alert].freeze
  EXTERNAL_CONTAINER_KEYS = %w[payload event metadata details].freeze
  EXCEPTION_CALLS = %i[raise fail].freeze
  LOG_CALLS = %i[debug info warn error fatal].freeze

  def initialize(root: Rails.root)
    @root = Pathname(root)
  end

  def findings
    source_paths.flat_map { |path| findings_for(path) }
  end

  def counts
    findings.group_by(&:category).transform_values(&:count).stringify_keys
  end

  def findings_for(path)
    relative = Pathname(path).relative_path_from(@root).to_s
    result = Prism.parse_file(path)
    raise "Could not parse #{relative}: #{result.errors.map(&:message).join(', ')}" unless result.success?

    collect(result.value, relative:)
  end

  private

  def source_paths
    ROOTS.flat_map { |root| Dir.glob(@root.join(root, "**/*.rb")) }
      .reject { |path| path.match?(EXCLUDED_PATHS) }
      .sort
  end

  def collect(node, relative:, ancestors: [])
    findings = findings_for_node(node, relative:, ancestors:)
    child_ancestors = ancestors + [ node ]
    findings + node.compact_child_nodes.flat_map do |child|
      collect(child, relative:, ancestors: child_ancestors)
    end
  end

  def findings_for_node(node, relative:, ancestors:)
    return [] if excluded_context?(ancestors)

    if node.is_a?(Prism::CallNode)
      call_findings(node, relative:)
    elsif node.is_a?(Prism::AssocNode)
      association_findings(node, relative:)
    else
      []
    end
  end

  def call_findings(node, relative:)
    arguments = node.arguments&.arguments || []

    if node.name == :render_error
      finding_for(:render_error, arguments[1], relative:)
    elsif node.name == :add && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :errors
      finding_for(:model_error, arguments[1], relative:)
    elsif node.name == :[]= && flash_receiver?(node.receiver) && RESPONSE_KEYS.include?(static_value(arguments[0]))
      finding_for(:response_field, arguments[1], relative:)
    else
      []
    end
  end

  def flash_receiver?(node)
    return false unless node.is_a?(Prism::CallNode)

    node.name == :flash || (node.name == :now && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :flash)
  end

  def association_findings(node, relative:)
    key = static_value(node.key)
    if RESPONSE_KEYS.include?(key)
      finding_for(:response_field, node.value, relative:)
    elsif key == "label" && serializer_surface?(relative)
      finding_for(:serializer_label, node.value, relative:)
    else
      []
    end
  end

  def finding_for(category, value_node, relative:)
    text = literal_text(value_node)
    return [] unless text

    [ Finding.new(category:, path: relative, line: value_node.location.start_line, text:) ]
  end

  def literal_text(node)
    case node
    when Prism::StringNode
      node.unescaped
    when Prism::InterpolatedStringNode
      node.location.slice
    end
  end

  # These contexts are machine/maintainer-facing rather than localizable copy.
  def excluded_context?(ancestors)
    ancestors.any? do |ancestor|
      (ancestor.is_a?(Prism::CallNode) && internal_call?(ancestor)) ||
        (ancestor.is_a?(Prism::AssocNode) && EXTERNAL_CONTAINER_KEYS.include?(static_value(ancestor.key))) ||
        (ancestor.is_a?(Prism::ConstantReadNode) && ancestor.name.to_s.match?(/Diagnostic|Command/))
    end
  end

  def internal_call?(node)
    return true if EXCEPTION_CALLS.include?(node.name)
    return false unless LOG_CALLS.include?(node.name)

    receiver = node.receiver
    receiver.is_a?(Prism::CallNode) && receiver.name == :logger
  end

  def static_value(node)
    case node
    when Prism::SymbolNode, Prism::StringNode
      node.unescaped
    end
  end

  def serializer_surface?(path)
    path.match?(%r{(?:serializer|presenter|payload|_tabs)\.rb$})
  end
end
