# Shared typed_artifacts enrichment: injects renderer_type into each
# entry under artifacts["typed_artifacts"] using the registered
# Syrus::PluginRegistry :artifact_renderer providers. Extracted from
# WorkflowSerializers#enrich_artifacts so the workflow-surface (Job detail
# payload) and chat-surface (chats#media) paths share one lookup
# implementation instead of duplicating it.
class TypedArtifactRenderer
  class << self
    def enrich(artifacts)
      typed = Array(artifacts)
      typed.filter_map do |entry|
        next unless entry.is_a?(Hash)

        renderer_type = artifact_renderer_map[entry["type"]]
        renderer_type ? entry.merge("renderer_type" => renderer_type) : entry
      end
    end

    private

    def artifact_renderer_map
      Syrus::PluginRegistry.providers_for(:artifact_renderer)
        .each_with_object({}) do |renderer, map|
          map[renderer.artifact_type] = renderer.renderer_type.to_s
        end
    end
  end
end
