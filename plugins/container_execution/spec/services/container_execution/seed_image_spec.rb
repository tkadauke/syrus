require "rails_helper"
require "tmpdir"

RSpec.describe ContainerExecution::SeedImage do
  Status = Data.define(:success?, :exitstatus)

  before do
    allow(ContainerExecution::Configuration).to receive(:docker_command_path).and_return("/usr/bin/docker")
  end

  around do |example|
    @previous_env = ENV.to_h
    Dir.mktmpdir("seed-image") do |dir|
      @workspace = dir
      example.run
    end
  ensure
    ENV.replace(@previous_env)
  end

  it "keeps the configured image when devcontainer support is disabled" do
    ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"] = "syrus-worker:test"
    expect(described_class.new(request).resolve).to eq("syrus-worker:test")
  end

  it "pulls a missing image declared by the repository spec" do
    enable_devcontainer
    spec = instance_double(ContainerExecution::DevcontainerSpec::Result, image: "ruby:3.4", build: nil)
    allow(ContainerExecution::DevcontainerSpec).to receive(:for_job).and_return(spec)
    runner = runner_returning(failure, success)

    expect(described_class.new(request, runner: runner).resolve).to eq("ruby:3.4")
    expect(runner).to have_received(:capture3).with("/usr/bin/docker", "pull", "ruby:3.4")
  end

  it "uses the spec captured before cloning instead of rereading repository content" do
    enable_devcontainer
    workflow = instance_double(Workflow, artifact: {
      "config" => { "image" => "ruby:3.4" },
      "source" => ".devcontainer.json",
      "revision" => "abc123"
    })
    expect(ContainerExecution::DevcontainerSpec).not_to receive(:for_job)
    runner = runner_returning(success)

    expect(described_class.new(request(workflow: workflow), runner: runner).resolve).to eq("ruby:3.4")
  end

  it "builds a deterministic image from a declared Dockerfile and context" do
    enable_devcontainer
    ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "#{@workspace}=#{@workspace}"
    FileUtils.mkdir_p(File.join(@workspace, ".devcontainer"))
    spec = instance_double(
      ContainerExecution::DevcontainerSpec::Result,
      image: nil,
      source: ".devcontainer/devcontainer.json",
      fingerprint: "a" * 64,
      build: { "dockerfile" => "Dockerfile.dev", "context" => "..", "args" => { "RUBY_VERSION" => "3.4" } }
    )
    allow(ContainerExecution::DevcontainerSpec).to receive(:for_job).and_return(spec)
    runner = runner_returning(failure, success)

    expect(described_class.new(request, runner: runner).resolve).to eq("syrus-devcontainer:#{'a' * 24}")
    expect(runner).to have_received(:capture3).with(
      "/usr/bin/docker", "build", "--tag", "syrus-devcontainer:#{'a' * 24}",
      "--file", File.join(@workspace, ".devcontainer", "Dockerfile.dev"),
      "--build-arg", "RUBY_VERSION=3.4", @workspace
    )
  end

  it "translates devcontainer build paths into the Docker host namespace" do
    enable_devcontainer
    host_workspace = "/docker-host/workflows/123"
    ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "#{@workspace}=#{host_workspace}"
    spec = instance_double(
      ContainerExecution::DevcontainerSpec::Result,
      image: nil,
      source: ".devcontainer/devcontainer.json",
      fingerprint: "b" * 64,
      build: { "dockerfile" => "Dockerfile", "context" => ".." }
    )
    allow(ContainerExecution::DevcontainerSpec).to receive(:for_job).and_return(spec)
    runner = runner_returning(failure, success)

    expect(described_class.new(request, runner: runner).resolve).to eq("syrus-devcontainer:#{'b' * 24}")
    expect(runner).to have_received(:capture3).with(
      "/usr/bin/docker", "build", "--tag", "syrus-devcontainer:#{'b' * 24}",
      "--file", "#{host_workspace}/.devcontainer/Dockerfile", host_workspace
    )
  end

  it "rejects a build path that is not mapped into the Docker host namespace" do
    enable_devcontainer
    spec = instance_double(
      ContainerExecution::DevcontainerSpec::Result,
      image: nil,
      source: ".devcontainer/devcontainer.json",
      fingerprint: "c" * 64,
      build: { "dockerfile" => "Dockerfile", "context" => ".." }
    )
    allow(ContainerExecution::DevcontainerSpec).to receive(:for_job).and_return(spec)
    runner = runner_returning(failure)

    expect { described_class.new(request, runner: runner).resolve }
      .to raise_error(ContainerExecution::SeedImage::BuildError, /not visible to the Docker host/)
  end

  def enable_devcontainer
    ENV["SYRUS_CONTAINER_EXECUTION_DEVCONTAINER"] = "true"
  end

  def request(workflow: nil)
    instance_double(
      Execution::Request,
      job: instance_double(Job, repository: Object.new),
      workflow: workflow,
      chdir: @workspace,
      mounts: nil
    )
  end

  def runner_returning(*statuses)
    double("command runner").tap do |runner|
      allow(runner).to receive(:capture3).and_return(*statuses.map { |status| [ "", "", status ] })
    end
  end

  def success = Status.new(success?: true, exitstatus: 0)
  def failure = Status.new(success?: false, exitstatus: 1)
end
