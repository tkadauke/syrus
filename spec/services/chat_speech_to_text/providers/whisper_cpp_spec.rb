require "rails_helper"

RSpec.describe ChatSpeechToText::Providers::WhisperCpp do
  def audio_file
    file = Tempfile.new([ "dictation", ".webm" ])
    file.binmode
    file.write("audio")
    file.rewind
    file
  end

  # Stands in for the real whisper.cpp CLI: parses just enough of the
  # argv shape (`-f <audio>`) to know where to write the `.txt` sidecar
  # file whisper.cpp itself would produce, so `extract_transcript` reads
  # it back exactly as it would in production.
  def fake_whisper_script(body)
    script = Tempfile.new([ "fake-whisper-cli", "" ])
    script.write(<<~BASH)
      #!/usr/bin/env bash
      audio_file=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -f) audio_file="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      #{body}
    BASH
    script.close
    FileUtils.chmod("+x", script.path)
    script.path
  end

  it "runs whisper.cpp through ProcessRunner and records a chat_stt SpawnedProcess row on success" do
    executable = fake_whisper_script('echo "hello world" > "${audio_file}.txt"')
    provider = described_class.new(executable: executable, model: "/models/base.bin")
    file = audio_file

    expect do
      @result = provider.transcribe_batch(
        ChatSpeechToText::Providers::TranscriptionRequest.new(
          audio: file,
          content_type: "audio/webm",
          language: nil,
          prompt: nil
        )
      )
    end.to change(SpawnedProcess, :count).by(1)

    expect(@result.text).to eq("hello world")
    expect(@result.provider).to eq("whisper_cpp")

    spawned = SpawnedProcess.last
    expect(spawned.kind).to eq("chat_stt")
    expect(spawned.outcome).to eq("succeeded")
    expect(spawned.command).to eq("#{executable} -m /models/base.bin -f [audio] -nt -np -otxt")
    expect(spawned.command).not_to include(file.path)
  ensure
    file&.close!
  end

  it "maps non-zero exits to transcription errors and records a failed chat_stt SpawnedProcess row" do
    executable = fake_whisper_script('echo "missing model" >&2; exit 1')
    provider = described_class.new(executable: executable, model: "/models/base.bin")
    file = audio_file

    expect do
      expect do
        provider.transcribe_batch(
          ChatSpeechToText::Providers::TranscriptionRequest.new(
            audio: file,
            content_type: "audio/webm",
            language: nil,
            prompt: nil
          )
        )
      end.to raise_error(ChatSpeechToText::Providers::TranscriptionError, /missing model/)
    end.to change(SpawnedProcess, :count).by(1)

    spawned = SpawnedProcess.last
    expect(spawned.kind).to eq("chat_stt")
    expect(spawned.outcome).to eq("failed")
  ensure
    file&.close!
  end

  it "raises when whisper.cpp exits cleanly with an empty transcript" do
    executable = fake_whisper_script('echo -n "" > "${audio_file}.txt"')
    provider = described_class.new(executable: executable, model: "/models/base.bin")
    file = audio_file

    expect do
      provider.transcribe_batch(
        ChatSpeechToText::Providers::TranscriptionRequest.new(
          audio: file,
          content_type: "audio/webm",
          language: nil,
          prompt: nil
        )
      )
    end.to raise_error(ChatSpeechToText::Providers::TranscriptionError, "whisper.cpp returned an empty transcript")
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
end
