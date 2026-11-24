module RuntimeImages
  # A provider rejected the credential for an operation. Distinguished from
  # other provider failures so operations can count and audit it separately.
  class AuthenticationError < ProviderError; end
end
