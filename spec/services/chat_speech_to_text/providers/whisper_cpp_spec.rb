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

  it "does not advertise streaming for the batch-only whisper.cpp CLI adapter" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SYRUS_STT_WHISPER_CPP_EXECUTABLE").and_return("/usr/local/bin/whisper-cli")
    allow(ENV).to receive(:[]).with("SYRUS_STT_WHISPER_CPP_MODEL").and_return("/models/base.bin")
    allow(ENV).to receive(:[]).with("SYRUS_STT_BACKEND_STREAMING").and_return("true")

    provider = described_class.from_env

    expect(provider).to be_batch
    expect(provider).not_to be_streaming
  end

  describe ".from_env" do
    def stub_env(executable:, model:)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_STT_WHISPER_CPP_EXECUTABLE").and_return(executable)
      allow(ENV).to receive(:[]).with("SYRUS_STT_WHISPER_CPP_MODEL").and_return(model)
    end

    it "falls back to the baked-in bundled paths when env vars are unset and the files exist" do
      stub_env(executable: nil, model: nil)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(described_class::BUNDLED_EXECUTABLE_PATH).and_return(true)
      allow(File).to receive(:exist?).with(described_class::BUNDLED_MODEL_PATH).and_return(true)

      provider = described_class.from_env

      expect(provider).to be_a(described_class)
      expect(provider.instance_variable_get(:@executable)).to eq(described_class::BUNDLED_EXECUTABLE_PATH)
      expect(provider.instance_variable_get(:@model)).to eq(described_class::BUNDLED_MODEL_PATH)
    end

    it "returns nil when env vars are unset and the bundled files are absent (preserves browser fallback)" do
      stub_env(executable: nil, model: nil)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(described_class::BUNDLED_EXECUTABLE_PATH).and_return(false)
      allow(File).to receive(:exist?).with(described_class::BUNDLED_MODEL_PATH).and_return(false)

      expect(described_class.from_env).to be_nil
    end

    it "prefers explicit env vars over the bundled defaults even when both exist" do
      stub_env(executable: "/custom/whisper-cli", model: "/custom/model.bin")
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(described_class::BUNDLED_EXECUTABLE_PATH).and_return(true)
      allow(File).to receive(:exist?).with(described_class::BUNDLED_MODEL_PATH).and_return(true)

      provider = described_class.from_env

      expect(provider.instance_variable_get(:@executable)).to eq("/custom/whisper-cli")
      expect(provider.instance_variable_get(:@model)).to eq("/custom/model.bin")
    end
  end
end
