module SecureFileDelivery
  INLINE_CONTENT_TYPES = %w[
    application/pdf
    image/gif
    image/jpeg
    image/png
    image/webp
  ].freeze

  private

  def send_secure_file(data, filename:, type:)
    content_type = type.to_s.split(";", 2).first.downcase.presence || "application/octet-stream"
    response.set_header("X-Content-Type-Options", "nosniff")
    response.set_header("Content-Security-Policy", "sandbox")

    send_data(
      data,
      filename: filename,
      type: type.presence || "application/octet-stream",
      disposition: INLINE_CONTENT_TYPES.include?(content_type) ? "inline" : "attachment"
    )
  end
end
