require "rails_helper"

RSpec.describe Admin::Transcripts::RawStream do
  it "reads transcript bytes in bounded chunks without materializing the column on the model" do
    run = Factories.job.initial_run
    transcript = ("é" * 40_000) + "\n"
    session = run.create_provider_session!(provider: "codex", session_id: "stream", transcript_jsonl: transcript)
    stream = described_class.new(session.id)

    expect(stream.bytesize).to eq(transcript.bytesize)
    expect(stream.each.to_a).to all(satisfy { |chunk| chunk.bytesize <= described_class::CHUNK_BYTES })
    expect(stream.each.to_a.join).to eq(transcript)
  end
end
