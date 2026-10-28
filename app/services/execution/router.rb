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
      backend_name = configured_backend_name(request)
      return local unless backend_name

      provider = Syrus::PluginRegistry.providers_for(:execution_backend).find do |candidate|
        candidate.backend_name == backend_name && candidate.available_for?(request)
      end
      return local unless provider

      provider.is_a?(Class) ? provider.new : provider
    rescue ActiveRecord::ActiveRecordError, SyrusYml::ParseError, SystemCallError
      local
    end

    def configured_backend_name(request)
      return unless request.kind.to_s == "grader"

      config_path = Pathname.new(request.mounts.workdir).join(SyrusYml::CONFIG_FILE)
      return unless config_path.file?

      SyrusYml.load_file(config_path).execution&.grader_backend
    end
  end
end
