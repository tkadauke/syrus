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
    return unless prepare_secure_file_delivery(etag: blob.checksum, immutable: immutable)

    content_type = blob.content_type.to_s.split(";", 2).first.downcase.presence || "application/octet-stream"
    disposition = INLINE_CONTENT_TYPES.include?(content_type) ? "inline" : "attachment"
    send_stream(
      filename: blob.filename.sanitized,
      disposition: blob.forced_disposition_for_serving || disposition,
      type: blob.content_type.presence || "application/octet-stream"
    ) do |stream|
      blob.download { |chunk| stream.write(chunk) }
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
