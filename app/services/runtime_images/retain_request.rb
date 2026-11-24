module RuntimeImages
  RetainRequest = Data.define(:namespace, :digest, :platform, :retain_until)
end
