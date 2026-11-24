module RuntimeImages
  PullRequest = Data.define(:namespace, :digest, :platform, :locator)
end
