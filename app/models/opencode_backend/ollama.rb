module OpencodeBackend
  class Ollama < Base
    def configured?(user)
      user.opencode_endpoint_url.present?
    end
  end
end
