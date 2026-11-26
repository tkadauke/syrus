module ContainerExecution
  class WorkflowArtifactContributor
    include Syrus::Plugin::WorkflowArtifactContributor

    ARTIFACT_KEY = "container_execution_devcontainer".freeze

    def self.for_job(job)
      return {} unless Configuration.devcontainer_enabled?

      spec = DevcontainerSpec.for_job(job)
      return {} unless spec

      {
        ARTIFACT_KEY => {
          "config" => spec.config,
          "source" => spec.source,
          "revision" => spec.revision
        }
      }
    end
  end
end
