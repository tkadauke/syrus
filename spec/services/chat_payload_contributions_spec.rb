require "rails_helper"

RSpec.describe ChatPayloadContributions do
  let(:repo) { Factories.repository }
  let(:chat) { ChatSession.create!(repository: repo, user: repo.user) }

  def contributor(payload)
    Class.new do
      include Syrus::Plugin::ChatPayloadContributor

      class_attribute :contribution
      def self.chat_payload(chat_session:, context:) = contribution
    end.tap { |klass| klass.contribution = payload }
  end

  def register(klass)
    Syrus::PluginRegistry.register(
      name: "payload_plugin", version: "1.0.0", provides: { chat_payload_contributor: klass }
    )
  end

  # Scoped to this contributor: real plugins contribute here too, so an exact
  # match would break whenever one is added.
  it "merges a contributor's keys into the payload" do
    register(contributor({ my_key: [ 1, 2 ] }))

    expect(described_class.payload(chat_session: chat, context: {}, existing_keys: [ :message ]))
      .to include(my_key: [ 1, 2 ])
  end

  # A contributor quietly winning over a core key would show up as the page
  # rendering wrong, not as an error, so it is an error.
  it "refuses to overwrite a key core already set" do
    register(contributor({ messages: [] }))

    expect {
      described_class.payload(chat_session: chat, context: {}, existing_keys: [ :messages ])
    }.to raise_error(described_class::KeyConflict, /messages/)
  end

  it "defaults paths and counts to empty for a contributor that declares neither" do
    klass = contributor({})

    expect(klass.chat_payload_paths(chat_session: chat)).to eq({})
    expect(klass.chat_payload_counts(chat_session: chat)).to eq({})
  end
end
