require "open3"
require "pathname"
require "timeout"

module ContainerExecution
  class SeedImage
    class BuildError < StandardError; end

    BUILD_TIMEOUT = 15.minutes

    def initialize(request, runner: Open3)
      @request = request
      @runner = runner
    end

    def resolve
      spec = devcontainer_spec
      return Configuration.image unless spec

      spec.image ? pull(spec.image) : build(spec)
    end

    private

    attr_reader :request, :runner

    def devcontainer_spec
      return unless Configuration.devcontainer_enabled? && request.job&.repository

      if request.workflow
        artifact = request.workflow.artifact(WorkflowArtifactContributor::ARTIFACT_KEY)
        return unless artifact.present?

        return DevcontainerSpec::Result.new(
          config: artifact.fetch("config"),
          source: artifact.fetch("source"),
          revision: artifact.fetch("revision")
        )
      end

      DevcontainerSpec.for_job(request.job)
    end

    def pull(image)
      return image if image_present?(image)

      run_docker!("pull", image)
      image
    end

    def build(spec)
      tag = "syrus-devcontainer:#{spec.fingerprint.first(24)}"
      return tag if image_present?(tag)

      build_config = spec.build.is_a?(Hash) ? spec.build : {}
      spec_directory = File.dirname(spec.source)
      dockerfile = build_config.fetch("dockerfile", "Dockerfile")
      context = build_config.fetch("context", ".")
      dockerfile_path = docker_host_path(workspace_path(spec_directory, dockerfile))
      context_path = docker_host_path(workspace_path(spec_directory, context))
      args = build_config.fetch("args", {}).flat_map { |key, value| [ "--build-arg", "#{key}=#{value}" ] }
      run_docker!("build", "--tag", tag, "--file", dockerfile_path, *args, context_path)
      tag
    end

    def workspace_path(base, relative)
      root = Pathname.new(workspace_root).expand_path
      candidate = root.join(base, relative).cleanpath
      unless candidate == root || candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")
        raise BuildError, "devcontainer build path escapes the repository workspace"
      end
      candidate.to_s
    end

    def workspace_root
      mount = request.mounts&.declared_mounts&.find { |candidate| candidate.include?(request.chdir) }
      mount&.host_path || request.chdir
    end

    def docker_host_path(worker_path)
      Configuration.host_path_for(worker_path) ||
        raise(BuildError, "devcontainer build path is not visible to the Docker host: #{worker_path}")
    end

    def image_present?(image)
      _stdout, _stderr, status = runner.capture3(Configuration.docker_command_path, "image", "inspect", image)
      status.success?
    end

    def run_docker!(*arguments)
      stdout, stderr, status = Timeout.timeout(BUILD_TIMEOUT) do
        runner.capture3(Configuration.docker_command_path, *arguments)
      end
      return if status.success?

      detail = stderr.presence || stdout.presence || "Docker exited with status #{status.exitstatus}"
      raise BuildError, detail.to_s.strip
    rescue Timeout::Error
      raise BuildError, "Docker seed-image operation timed out after #{BUILD_TIMEOUT.to_i} seconds"
    end
  end
end
