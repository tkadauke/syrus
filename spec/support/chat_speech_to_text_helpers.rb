module ChatSpeechToTextHelpers
  def stub_no_chat_speech_to_text_backend!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SYRUS_STT_PROVIDER").and_return(nil)
  end
end

RSpec.configure do |config|
  config.include ChatSpeechToTextHelpers
end
