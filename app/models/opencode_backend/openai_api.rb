module OpencodeBackend
  class OpenaiApi < Base
    def configured?(user)
      user.opencode_api_key.present?
    end
  end
end
