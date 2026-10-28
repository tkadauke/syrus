class Coworkers::AvatarUpload
  MAX_BYTES = 5.megabytes
  MAX_DIMENSION = 512

  def self.attach!(coworker, upload)
    raise ArgumentError, "avatar must be an image" unless upload.content_type.to_s.start_with?("image/")
    raise ArgumentError, "avatar must be smaller than 5 MB" if upload.size > MAX_BYTES

    resized = ImageProcessing::Vips.source(upload.tempfile).resize_to_limit(MAX_DIMENSION, MAX_DIMENSION).call
    coworker.avatar.attach(io: resized, filename: upload.original_filename, content_type: upload.content_type)
  ensure
    resized&.close!
  end
end
