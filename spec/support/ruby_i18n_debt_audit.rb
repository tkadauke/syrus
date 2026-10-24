class RubyI18nDebtAudit
  Finding = Data.define(:category, :path, :line, :text)

  ROOTS = %w[app plugins].freeze
  EXCLUDED_PATHS = %r{/(?:spec|test|log|vendor)/|/db/|/config/}.freeze
  INTERNAL_CONTEXT = /(?:Rails\.logger|logger\.|raise\b|fail\b|warn\b|exception|diagnostic|command|stdout|stderr)/i

  PATTERNS = {
    render_error: /render_error\(\s*[^,]+,\s*(?<quote>["'])(?<text>.+?)\k<quote>/,
    response_field: /\b(?:message|notice|alert):\s*(?<quote>["'])(?<text>.+?)\k<quote>/,
    model_error: /errors\.add\(\s*[^,]+,\s*(?<quote>["'])(?<text>.+?)\k<quote>/,
    serializer_label: /\blabel:\s*(?<quote>["'])(?<text>.+?)\k<quote>/
  }.freeze

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

    File.readlines(path).flat_map.with_index(1) do |line, line_number|
      next [] if excluded_line?(line)

      PATTERNS.filter_map do |category, pattern|
        next if category == :serializer_label && !serializer_surface?(relative)
        match = line.match(pattern)
        next unless match

        Finding.new(category:, path: relative, line: line_number, text: match[:text])
      end
    end
  end

  private

  def source_paths
    ROOTS.flat_map { |root| Dir.glob(@root.join(root, "**/*.rb")) }
      .reject { |path| path.match?(EXCLUDED_PATHS) }
      .sort
  end

  # These are machine/maintainer-facing channels, not copy shown as product UI.
  # External payload values are also excluded: translating them changes a protocol.
  def excluded_line?(line)
    stripped = line.lstrip
    stripped.start_with?("#") || line.match?(INTERNAL_CONTEXT) ||
      line.match?(/(?:payload|event|metadata|details):\s*\{/) ||
      line.match?(/\b(?:code|status|type|kind|token):\s*["']/)
  end

  def serializer_surface?(path)
    path.match?(%r{(?:serializer|presenter|payload|_tabs)\.rb$})
  end
end
