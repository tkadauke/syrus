module SecureFileDelivery
  extend ActiveSupport::Concern

  include ActiveStorage::Streaming

  INLINE_CONTENT_TYPES = %w[
    application/pdf
    image/gif
    image/jpeg
    image/png
    image/webp
  ].freeze

  private

  def send_secure_file(data, filename:, type:, etag: nil, immutable: false)
    return unless prepare_secure_file_delivery(etag: etag, immutable: immutable)

    content_type = type.to_s.split(";", 2).first.downcase.presence || "application/octet-stream"

    send_data(
      data,
      filename: filename,
      type: type.presence || "application/octet-stream",
      disposition: INLINE_CONTENT_TYPES.include?(content_type) ? "inline" : "attachment"
    )
  end

  def send_secure_blob(blob, immutable: false)
    return unless immutable || prepare_secure_file_delivery(etag: blob.checksum, immutable: false)

    chunks = blob_download_chunks(blob)
    first_chunk = chunks.next
  rescue StopIteration
    stream_secure_blob(blob, chunks: [].each, immutable: immutable)
  else
    stream_secure_blob(blob, chunks: chunks, first_chunk: first_chunk, immutable: immutable)
  end

  def stream_secure_blob(blob, chunks:, first_chunk: nil, immutable:)
    prepare_secure_file_delivery(etag: blob.checksum, immutable: true) if immutable

    content_type = blob.content_type.to_s.split(";", 2).first.downcase.presence || "application/octet-stream"
    disposition = INLINE_CONTENT_TYPES.include?(content_type) ? "inline" : "attachment"
    send_stream(
      filename: blob.filename.sanitized,
      disposition: blob.forced_disposition_for_serving || disposition,
      type: content_type
    ) do |stream|
      stream.write(first_chunk) if first_chunk
      loop { stream.write(chunks.next) }
    end
  end

  # Pull the first storage chunk before send_stream commits its headers. This
  # preserves callers' retryable JSON response when storage is unreachable,
  # while the remaining chunks still flow directly from storage to the client.
  def blob_download_chunks(blob)
    Enumerator.new do |chunks|
      blob.download { |chunk| chunks << chunk }
    end
  end

  def prepare_secure_file_delivery(etag:, immutable:)
    response.set_header("X-Content-Type-Options", "nosniff")
    response.set_header("Content-Security-Policy", "sandbox")

    if immutable
      expires_in 31_536_000.seconds, public: false, immutable: true
      true
    else
      stale?(etag: etag)
    end
  end
end
