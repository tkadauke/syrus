module OpencodeBackend
  class Base
    BACKENDS = {
      "openai_api" => "OpencodeBackend::OpenaiApi",
      "ollama" => "OpencodeBackend::Ollama",
      "azure_openai" => "OpencodeBackend::AzureOpenai"
    }.freeze

    def self.for(name)
      BACKENDS.fetch(name.to_s).constantize.new
    end

    def configured?(_user)
      raise NotImplementedError
    end
  end
end
