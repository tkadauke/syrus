require "rails_helper"

RSpec.describe ChatSpeechToText::Providers::WhisperCpp do
  def audio_file
    file = Tempfile.new([ "dictation", ".webm" ])
    file.binmode
    file.write("audio")
    file.rewind
    file
  end

  it "runs whisper.cpp with argv and returns stdout text" do
    provider = described_class.new(executable: "/usr/local/bin/whisper-cli", model: "/models/base.bin")
    file = audio_file
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return([ "hello world\n", "", status ])

    result = provider.transcribe_batch(
      ChatSpeechToText::Providers::TranscriptionRequest.new(
        audio: file,
        content_type: "audio/webm",
        language: nil,
        prompt: nil
      )
    )

    expect(result.text).to eq("hello world")
    expect(result.provider).to eq("whisper_cpp")
    expect(Open3).to have_received(:capture3).with(
      "/usr/local/bin/whisper-cli",
      "-m", "/models/base.bin",
      "-f", file.path,
      "-nt",
      "-np",
      "-otxt",
      stdin_data: "",
      binmode: true
    )
  ensure
    file&.close!
  end

  it "maps non-zero exits to transcription errors" do
    provider = described_class.new(executable: "/usr/local/bin/whisper-cli", model: "/models/base.bin")
    file = audio_file
    status = instance_double(Process::Status, success?: false)
    allow(Open3).to receive(:capture3).and_return([ "", "missing model", status ])

    expect do
      provider.transcribe_batch(
        ChatSpeechToText::Providers::TranscriptionRequest.new(
          audio: file,
          content_type: "audio/webm",
          language: nil,
          prompt: nil
        )
      )
    end.to raise_error(ChatSpeechToText::Providers::TranscriptionError, "missing model")
  ensure
    file&.close!
  end
end
