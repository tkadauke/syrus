module AdminTranscriptDelivery
  extend ActiveSupport::Concern

  private

  def stream_transcript(session, filename:)
    stream = Admin::Transcripts::RawStream.new(session.id)
    response.set_header("Content-Type", "application/jsonl")
    response.set_header("Content-Disposition", ActionDispatch::Http::ContentDisposition.format(disposition: "attachment", filename: filename))
    response.set_header("Content-Length", stream.bytesize.to_s)
    response.set_header("X-Content-Type-Options", "nosniff")
    self.response_body = stream
  end
end
