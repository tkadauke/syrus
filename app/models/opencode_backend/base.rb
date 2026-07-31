module OpenCodeBackend
  class Base
    BACKENDS = {
      "openai_api" => "OpenCodeBackend::OpenaiApi",
      "ollama" => "OpenCodeBackend::Ollama",
      "azure_openai" => "OpenCodeBackend::AzureOpenai"
    }.freeze

    def self.for(name)
      BACKENDS.fetch(name.to_s).constantize.new
    end

    def configured?(_user)
      raise NotImplementedError
    end
  end
end
