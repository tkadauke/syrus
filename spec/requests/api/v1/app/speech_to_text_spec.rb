require "rails_helper"

RSpec.describe "API: /api/v1/app speech-to-text", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:chat) { ChatSession.create!(user: user) }
  let(:provider) do
    instance_double(
      ChatSpeechToText::Providers::Base,
      batch?: true,
      streaming?: false
    )
  end

  def parse_body
    JSON.parse(response.body)
  end

  def enable_speech_to_text!
    Feature.find_or_create_by!(slug: "chat_speech_to_text") do |feature|
      feature.category = "Labs"
      feature.name = "Chat speech-to-text"
    end.update!(enabled: true)
  end

  def upload_file(name: "dictation.webm", content_type: "audio/webm", content: "audio-bytes")
    file = Tempfile.new([ "dictation", File.extname(name) ])
    file.binmode
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, original_filename: name)
  end

  it "returns 404 for batch and stream endpoints when the feature is disabled" do
    sign_in_as(user)

    post "/api/v1/app/chats/#{chat.id}/speech_to_text"
    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("speech_to_text_disabled")

    post "/api/v1/app/chats/#{chat.id}/speech_to_text/stream"
    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("speech_to_text_disabled")
  end

  it "returns a deterministic backend-unavailable response when backend STT is not configured" do
    sign_in_as(user)
    enable_speech_to_text!

    post "/api/v1/app/chats/#{chat.id}/speech_to_text"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("speech_to_text_backend_unavailable")
  end

  it "transcribes a valid short audio upload without starting a chat turn" do
    sign_in_as(user)
    enable_speech_to_text!
    result = ChatSpeechToText::Providers::TranscriptionResult.new(
      text: "ship the fix",
      segments: [],
      provider: "test",
      confidence: nil
    )
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(provider)
    allow(provider).to receive(:transcribe_batch).and_return(result)

    message_count = ChatMessage.count
    queued_message_count = ChatQueuedMessage.count

    post "/api/v1/app/chats/#{chat.id}/speech_to_text", params: {
      file: upload_file,
      duration_seconds: "12",
      language: "en"
    }

    expect(response).to have_http_status(:ok)
    expect(ChatMessage.count).to eq(message_count)
    expect(ChatQueuedMessage.count).to eq(queued_message_count)
    expect(parse_body["transcript"]).to eq(
      "text" => "ship the fix",
      "source" => "backend_batch",
      "confidence" => nil
    )
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }).not_to include(ChatTurnJob)
    expect(provider).to have_received(:transcribe_batch).with(
      have_attributes(content_type: "audio/webm", language: "en", prompt: nil)
    )
  end

  it "returns a structured fallback-safe error when backend transcription fails" do
    sign_in_as(user)
    enable_speech_to_text!
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(provider)
    allow(provider).to receive(:transcribe_batch).and_raise(ChatSpeechToText::Providers::TranscriptionError, "model unavailable")

    post "/api/v1/app/chats/#{chat.id}/speech_to_text", params: { file: upload_file }

    expect(response).to have_http_status(:bad_gateway)
    expect(parse_body.dig("error", "code")).to eq("speech_to_text_transcription_failed")
    expect(parse_body.dig("error", "message")).to eq("model unavailable")
    expect(ChatMessage.count).to eq(0)
  end

  it "rejects a missing file" do
    sign_in_as(user)
    enable_speech_to_text!
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(provider)

    post "/api/v1/app/chats/#{chat.id}/speech_to_text"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("missing_file")
  end

  it "rejects unsupported audio content types" do
    sign_in_as(user)
    enable_speech_to_text!
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(provider)

    post "/api/v1/app/chats/#{chat.id}/speech_to_text", params: {
      file: upload_file(name: "notes.txt", content_type: "text/plain", content: "not audio")
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("unsupported_content_type")
  end

  it "rejects oversized uploads before calling the backend" do
    sign_in_as(user)
    enable_speech_to_text!
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(provider)
    expect(provider).not_to receive(:transcribe_batch)

    post "/api/v1/app/chats/#{chat.id}/speech_to_text", params: {
      file: upload_file(content: "x" * (Api::V1::App::SpeechToTextController::MAX_AUDIO_BYTES + 1))
    }

    expect(response).to have_http_status(:content_too_large)
    expect(parse_body.dig("error", "code")).to eq("audio_too_large")
  end

  it "rejects audio over the duration limit" do
    sign_in_as(user)
    enable_speech_to_text!
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(provider)
    expect(provider).not_to receive(:transcribe_batch)

    post "/api/v1/app/chats/#{chat.id}/speech_to_text", params: {
      file: upload_file,
      duration_seconds: (Api::V1::App::SpeechToTextController::MAX_AUDIO_DURATION_SECONDS + 1).to_s
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("audio_too_long")
  end

  it "does not allow uploading to another user's chat" do
    sign_in_as(user)
    enable_speech_to_text!
    other_chat = ChatSession.create!(user: Factories.user)
    allow(ChatSpeechToText::Providers).to receive(:configured).and_return(provider)
    expect(provider).not_to receive(:transcribe_batch)

    post "/api/v1/app/chats/#{other_chat.id}/speech_to_text", params: { file: upload_file }

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("not_found")
  end
end
