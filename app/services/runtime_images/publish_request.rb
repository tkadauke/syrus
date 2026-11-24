module RuntimeImages
  PublishRequest = Data.define(:namespace, :source_kind, :source_ref, :source_digest, :platform, :provenance, :payload)
end
