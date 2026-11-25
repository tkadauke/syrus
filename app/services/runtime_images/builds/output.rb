module RuntimeImages
  module Builds
    # What a builder hands back: the OCI payload to publish and the digest of
    # the source context it actually consumed (checked against the capture).
    Output = Struct.new(:payload, :source_digest, :provenance, keyword_init: true)
  end
end
