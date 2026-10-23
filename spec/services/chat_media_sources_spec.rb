require "rails_helper"

RSpec.describe ChatMediaSources do
  def media_source(kind:, panel: {})
    Class.new do
      include Syrus::Plugin::ChatMediaSource

      class_attribute :kind, :panel

      def self.chat_media_kind = kind
      def self.chat_media_panel(chat_session:) = panel
    end.tap do |source|
      source.kind = kind
      source.panel = panel
    end
  end

  let(:chat_session) { instance_double(ChatSession) }
  let(:first_source) { media_source(kind: :diagram, panel: { diagrams: [ 1 ], shared: "first" }) }
  let(:second_source) { media_source(kind: "recording", panel: { recordings: [ 2 ], shared: "second" }) }

  before do
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for)
      .with(:chat_media_source)
      .and_return([ first_source, second_source ])
  end

  it "combines the core source with registered plugin sources" do
    expect(described_class.all).to eq([
      ChatMedia::ChatImageSource,
      first_source,
      second_source
    ])
    expect(described_class.kinds).to eq(%w[ chat_image diagram recording ])
  end

  it "finds a source using either a string or symbol kind" do
    expect(described_class.for_kind("diagram")).to eq(first_source)
    expect(described_class.for_kind(:recording)).to eq(second_source)
    expect(described_class.for_kind(:missing)).to be_nil
  end

  it "merges each source's contribution to the media panel in registry order" do
    expect(described_class.panel(chat_session: chat_session)).to eq(
      diagrams: [ 1 ],
      recordings: [ 2 ],
      shared: "second"
    )
  end
end
