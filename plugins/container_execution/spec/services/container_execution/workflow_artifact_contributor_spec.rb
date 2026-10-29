require "rails_helper"

RSpec.describe ContainerExecution::WorkflowArtifactContributor do
  let(:job) { instance_double(Job) }

  around do |example|
    previous = ENV["SYRUS_CONTAINER_EXECUTION_DEVCONTAINER"]
    example.run
  ensure
    ENV["SYRUS_CONTAINER_EXECUTION_DEVCONTAINER"] = previous
  end

  it "does not read repository content while the feature is disabled" do
    ENV.delete("SYRUS_CONTAINER_EXECUTION_DEVCONTAINER")
    expect(ContainerExecution::DevcontainerSpec).not_to receive(:for_job)

    expect(described_class.for_job(job)).to eq({})
  end

  it "serializes the immutable default-branch spec into workflow input" do
    ENV["SYRUS_CONTAINER_EXECUTION_DEVCONTAINER"] = "true"
    spec = ContainerExecution::DevcontainerSpec::Result.new(
      config: { "image" => "ruby:3.4" },
      source: ".devcontainer.json",
      revision: "abc123"
    )
    allow(ContainerExecution::DevcontainerSpec).to receive(:for_job).with(job).and_return(spec)

    expect(described_class.for_job(job)).to eq(
      "container_execution_devcontainer" => {
        "config" => { "image" => "ruby:3.4" },
        "source" => ".devcontainer.json",
        "revision" => "abc123"
      }
    )
  end
end
