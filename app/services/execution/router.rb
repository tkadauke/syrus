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
      backend_name = configured_backend_name(request)
      return local if request.kind.to_s == "grader" && !backend_name

      provider = Syrus::PluginRegistry.providers_for(:execution_backend).find do |candidate|
        (!backend_name || candidate.backend_name == backend_name) && candidate.available_for?(request)
      end
      return provider.is_a?(Class) ? provider.new : provider if provider
      raise BackendUnavailable, "no execution backend is available for #{request.workload_policy.name}" if fail_closed?(request)

      local
    rescue ActiveRecord::ActiveRecordError, SyrusYml::ParseError, SystemCallError
      raise BackendUnavailable, "execution backend availability could not be verified" if fail_closed?(request)
      local
    end

    def fail_closed?(request) = request.workload_policy&.fail_closed? == true

    def configured_backend_name(request)
      return unless request.kind.to_s == "grader"

      config_path = Pathname.new(request.mounts.workdir).join(SyrusYml::CONFIG_FILE)
      return unless config_path.file?

      SyrusYml.load_file(config_path).execution&.grader_backend
    end
  end
end
