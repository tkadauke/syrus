module ContainerExecution
  extend Syrus::PluginApi

  syrus_plugin "container_execution" do
    requires_syrus nil
    experimental true
    display_name "Container Execution"
    description "Runs configured grader commands inside a constrained container execution backend."
    long_description "Container Execution provides an alternate Execution::Backend for grader subprocesses. " \
      "It maps Syrus execution requests directly onto container bind mounts, network policy, and resource limits, " \
      "then lets core fall back to local execution whenever the plugin is disabled or not configured."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/container_execution.svg"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true

    execution_backend execution_backend: "ContainerExecution::Backend"
    provides workflow_artifact_contributor: "ContainerExecution::WorkflowArtifactContributor",
             worker_capability_probe: "ContainerExecution::CoworkerCapabilityProbe"
  end
end
