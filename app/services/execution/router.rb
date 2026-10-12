module Execution
  class Router < Backend
    def initialize(local: Local.new)
      @local = local
    end

    def run(request)
      backend_for(request).run(request)
    end

    private

    attr_reader :local

    def backend_for(request)
      provider = Syrus::PluginRegistry.providers_for(:execution_backend).find do |candidate|
        candidate.available_for?(request)
      end
      return local unless provider

      provider.is_a?(Class) ? provider.new : provider
    rescue ActiveRecord::ActiveRecordError
      local
    end
  end
end
