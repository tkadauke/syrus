module OpenCodeBackend
  class AzureOpenai < Base
    def configured?(user)
      user.opencode_api_key.present? && user.opencode_endpoint_url.present?
    end
  end
end
