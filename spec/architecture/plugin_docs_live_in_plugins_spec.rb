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
end
