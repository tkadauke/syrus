module RuntimeImages
  RevokeRequest = Data.define(:namespace, :digest, :platform, :reason)
end
