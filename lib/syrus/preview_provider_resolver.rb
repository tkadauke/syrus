module Syrus
  # Finds the first registered :preview_provider that detects the given repo path.
  # Called by the preview hosting system to select the right provider at runtime.
  class PreviewProviderResolver
    def self.for(repo_path)
      Syrus::PluginRegistry.providers_for(:preview_provider).find do |provider|
        provider.detect?(repo_path)
      end
    end
  end
end
