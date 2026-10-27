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
      return local if request.execution_backend.to_s == "local"

      provider = Syrus::PluginRegistry.providers_for(:execution_backend).find do |candidate|
        requested_backend?(candidate, request.execution_backend) &&
          candidate.available_for?(request)
      end
      return local unless provider

      provider.is_a?(Class) ? provider.new : provider
    rescue ActiveRecord::ActiveRecordError
      local
    end

    def requested_backend?(candidate, requested)
      requested = requested.to_s.strip
      return true if requested.blank?
      return candidate.execution_backend_name.to_s == requested if candidate.respond_to?(:execution_backend_name)

      candidate_name(candidate) == requested
    end

    def candidate_name(candidate)
      name = candidate.is_a?(Class) ? candidate.name : candidate.class.name
      name.to_s.sub(/::Backend\z/, "").underscore
    end
  end
end
