module Execution
  class Router < Backend
    class BackendUnavailable < StandardError; end
    def initialize(local: Local.new)
      @local = local
    end

    def run(request)
      validate_request!(request)
      backend_for(request).run(request)
    end

    private

    attr_reader :local

    def backend_for(request)
      provider = Syrus::PluginRegistry.providers_for(:execution_backend).find do |candidate|
        candidate.available_for?(request)
      end
      return provider.is_a?(Class) ? provider.new : provider if provider
      raise BackendUnavailable, "no execution backend is available for #{request.workload_policy.name}" if fail_closed?(request)

      local
    rescue ActiveRecord::ActiveRecordError
      raise BackendUnavailable, "execution backend availability could not be verified" if fail_closed?(request)
      local
    end

    def fail_closed?(request) = request.workload_policy&.fail_closed? == true
  end
end
