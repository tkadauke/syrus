require "rails_helper"

RSpec.describe ContainerExecution::Configuration do
  around do |example|
    previous_env = ENV.to_h
    example.run
  ensure
    ENV.replace(previous_env)
  end

  describe ".docker_image_namespace" do
    it "defaults to the worker hostname and Docker transport" do
      ENV["DOCKER_HOST"] = "tcp://docker.internal:2375"
      allow(SyrusVersion).to receive(:hostname).and_return("worker-a")

      expect(described_class.docker_image_namespace).to eq("worker-a:tcp://docker.internal:2375")
    end

    it "uses an explicit namespace for workers sharing one remote daemon" do
      ENV["SYRUS_CONTAINER_EXECUTION_DOCKER_NAMESPACE"] = "shared-builder"

      expect(described_class.docker_image_namespace).to eq("shared-builder")
    end
  end
end
