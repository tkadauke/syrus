require "rails_helper"

# The panel is a generic multi-format viewer (JOB-3864), but the file -> viewer
# mapping was a hardcoded switch, so every new kind meant editing core.
RSpec.describe PreviewPanel::EntryMetadata do
  def provider(kinds)
    Class.new do
      include Syrus::Plugin::PreviewPanelViewer
      class << self; attr_accessor :kinds; end
      def self.viewer_kinds = kinds
    end.tap { |klass| klass.kinds = kinds }
  end

  def with_providers(providers)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:preview_panel_viewer).and_return(providers)
  end

  it "keeps core's built-in kinds" do
    with_providers([])

    expect(described_class.viewer_kind("index.html")).to eq("html")
    expect(described_class.viewer_kind("notes.md")).to eq("markdown")
    expect(described_class.viewer_kind("spec.pdf")).to eq("pdf")
    expect(described_class.viewer_kind("logo.svg")).to eq("image")
    expect(described_class.viewer_kind("data.bin")).to eq("unsupported")
  end

  it "lets a plugin claim a kind core does not know" do
    with_providers([ provider([ { kind: "mermaid", extensions: [ ".mmd" ] } ]) ])

    expect(described_class.viewer_kind("flow.mmd")).to eq("mermaid")
  end

  it "matches on content type as well as extension" do
    with_providers([ provider([ { kind: "csv", content_types: [ "text/csv" ] } ]) ])

    expect(described_class.viewer_kind("rows.csv")).to eq("csv")
  end

  # A plugin extends the set; it does not reinterpret a file core already
  # knows how to show, or one plugin could quietly break every HTML panel.
  it "does not let a plugin override a built-in kind" do
    with_providers([ provider([ { kind: "hijacked", extensions: [ ".html" ] } ]) ])

    expect(described_class.viewer_kind("index.html")).to eq("html")
  end

  it "falls back to source text when a provider raises" do
    broken = Class.new do
      include Syrus::Plugin::PreviewPanelViewer
      def self.viewer_kinds = raise("boom")
    end
    with_providers([ broken ])

    expect(described_class.viewer_kind("flow.mmd")).to eq("unsupported")
  end

  it "ignores an entry with no kind rather than returning a blank viewer" do
    with_providers([ provider([ { extensions: [ ".mmd" ] } ]) ])

    expect(described_class.viewer_kind("flow.mmd")).to eq("unsupported")
  end
end
