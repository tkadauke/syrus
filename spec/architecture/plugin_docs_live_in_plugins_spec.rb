require "rails_helper"

# A plugin's own documentation lives in the plugin, so deleting the plugin
# directory removes its docs with it.
#
# Core docs may still *mention* a bundled plugin -- plugins.md describes the
# whole model, and cross-references are fine. What must not happen is a doc
# file whose entire subject is one plugin sitting in core, because that is a
# trace the plugin cannot take with it.
RSpec.describe "plugin documentation placement" do
  CORE_DOCS = Rails.root.join("config/syrus_docs")

  def plugin_names
    Rails.root.join("plugins").children.select(&:directory?).map { |dir| dir.basename.to_s }
  end

  it "has plugins to check" do
    expect(plugin_names).not_to be_empty
  end

  it "keeps no core doc file named after a plugin" do
    strays = plugin_names.select { |name| CORE_DOCS.join("#{name}.md").exist? }

    expect(strays).to be_empty,
      "these plugin docs belong in plugins/<name>/docs/syrus_docs/:\n  #{strays.join("\n  ")}"
  end

  it "puts a plugin's docs where the search looks for them" do
    misplaced = plugin_names.filter_map do |name|
      docs = Rails.root.join("plugins", name, "docs")
      next unless docs.exist?

      stray = Dir.glob(docs.join("*.md"))
      "#{name}: #{stray.map { |p| File.basename(p) }.join(', ')}" if stray.any?
    end

    expect(misplaced).to be_empty,
      "docs must sit under docs/syrus_docs/, which is where SearchSyrusDocsTool reads:\n  #{misplaced.join("\n  ")}"
  end

  # Name matching alone missed four docs -- insight_jobs, memory_audit_history,
  # repository_throughput_metrics, sccache_build_cache -- whose subject was a
  # plugin under a different title. A doc that leans this heavily on one
  # plugin's constants is documenting that plugin, wherever it happens to sit.
  #
  # Passing mentions are fine and common (multi_worker names GitHistory,
  # preview_panels names Mockups), which is why the bar is deliberately well
  # above them.
  PLUGIN_REFERENCE_LIMIT = 4

  # plugins.md is the plugin model itself: naming many plugins is the point.
  DELIBERATE_CORE_DOCS = %w[plugins].freeze

  def plugin_modules
    Rails.root.join("plugins").children.select(&:directory?).filter_map do |dir|
      name = dir.basename.to_s
      lib = dir.join("lib", "#{name}.rb")
      next unless lib.exist?

      mod = lib.read.match(/^module (\w+)/)&.captures&.first
      [ mod, name ] if mod
    end.to_h
  end

  it "keeps no core doc that is really about one plugin" do
    modules = plugin_modules
    offenders = Dir.glob(CORE_DOCS.join("*.md")).filter_map do |path|
      stem = File.basename(path, ".md")
      next if DELIBERATE_CORE_DOCS.include?(stem)

      text = File.read(path)
      counts = modules.each_with_object(Hash.new(0)) do |(mod, plugin), acc|
        acc[plugin] += text.scan(/(?<![:\w])#{Regexp.escape(mod)}::/).size
      end
      total = counts.values.sum
      next if total < PLUGIN_REFERENCE_LIMIT

      "#{stem}.md (#{counts.reject { |_, n| n.zero? }.sort_by { |_, n| -n }.to_h})"
    end

    expect(offenders).to be_empty, <<~MSG
      These core docs reference plugin internals heavily enough to be plugin
      documentation. Move them to plugins/<name>/docs/syrus_docs/, or add the
      stem to DELIBERATE_CORE_DOCS with a reason:
        #{offenders.join("\n  ")}
    MSG
  end
end
