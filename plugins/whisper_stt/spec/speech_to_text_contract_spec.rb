require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe WhisperStt::SpeechToTextServices do
  subject(:provider) { described_class }
  let(:contexts) { %i[speech_to_text_provider].index_with { Syrus::Plugin::Context::ServiceContext.new } }
  let(:decline_contexts) { %i[speech_to_text_provider].index_with { Syrus::Plugin::Context::ServiceContext.new(enabled: false) } }

  it_behaves_like "a valid speech_to_text provider", plugin: "whisper_stt", provider: "WhisperStt::SpeechToTextServices",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
