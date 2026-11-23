module SourceControl
  module Providers
    module_function

    def all
      Syrus::Plugin::ServiceProvider.providers(:source_control_provider)
    end

    def for_repository(repository)
      all.find { |provider| provider.available_for?(repository) }
    end
  end
end
