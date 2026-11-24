require "rails_helper"
require "tmpdir"

RSpec.describe ContainerExecution::SeedImage do
  SeedImageCommandStatus = Data.define(:success?, :exitstatus)

  before do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
    allow(ContainerExecution::Configuration).to receive(:docker_command_path).and_return("/usr/bin/docker")
  end

  after { clear_solid_queue_test_tables! }

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
      revision: "a" * 40,
      fingerprint: "a" * 64,
      build: { "dockerfile" => "Dockerfile.dev", "context" => "..", "args" => { "RUBY_VERSION" => "3.4" } }
    )
    allow(ContainerExecution::DevcontainerSpec).to receive(:for_job).and_return(spec)
    runner = runner_returning(failure, failure, success)

    expect(described_class.new(request, runner: runner).resolve).to eq("syrus-devcontainer:#{'a' * 24}")
    expect(runner).to have_received(:capture3).with(
      "/usr/bin/docker", "build", "--tag", "syrus-devcontainer:#{'a' * 24}",
      "--file", File.join(@workspace, ".devcontainer", "Dockerfile.dev"),
      "--build-arg", "RUBY_VERSION=3.4", @workspace
    )
  end

  it "builds exactly once when two Workflows resolve the same revision concurrently" do
    enable_devcontainer
    ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "#{@workspace}=#{@workspace}"
    repository = instance_double(Repository, id: 42)
    spec = ContainerExecution::DevcontainerSpec::Result.new(
      config: { "build" => { "dockerfile" => "Dockerfile", "context" => ".." } },
      source: ".devcontainer/devcontainer.json",
      revision: "d" * 40
    )
    tag = "syrus-devcontainer:#{spec.fingerprint.first(24)}"
    semaphore = ConcurrentSemaphore.new
    image_store = ConcurrentImageStore.new
    runners = 2.times.map { ConcurrentRunner.new(semaphore, image_store) }
    artifact = { "config" => spec.config, "source" => spec.source, "revision" => spec.revision }
    requests = 2.times.map do
      request(repository: repository, workflow: instance_double(Workflow, artifact: artifact))
    end

    threads = requests.zip(runners).map do |concurrent_request, runner|
      Thread.new do
        described_class.new(
          concurrent_request,
          runner: runner,
          semaphore: semaphore,
          sleeper: ->(_) { Thread.pass },
          image_namespace: "shared-daemon"
        ).resolve
      end
    end

    expect(threads.map(&:value)).to all(eq(tag))
    expect(image_store.build_count).to eq(1)
    namespace_key = Digest::SHA256.hexdigest("shared-daemon").first(16)
    expect(semaphore.keys).to all(eq("devcontainer_build:#{namespace_key}:42:#{'d' * 40}"))
  end

  it "does not serialize builds in distinct worker-local Docker image stores" do
    enable_devcontainer
    ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "#{@workspace}=#{@workspace}"
    repository = instance_double(Repository, id: 42)
    spec = ContainerExecution::DevcontainerSpec::Result.new(
      config: { "build" => { "dockerfile" => "Dockerfile", "context" => ".." } },
      source: ".devcontainer/devcontainer.json",
      revision: "e" * 40
    )
    artifact = { "config" => spec.config, "source" => spec.source, "revision" => spec.revision }
    semaphore = ConcurrentSemaphore.new
    runners = [ LocalImageRunner.new, LocalImageRunner.new ]

    threads = runners.each_with_index.map do |runner, index|
      concurrent_request = request(repository: repository, workflow: instance_double(Workflow, artifact: artifact))
      Thread.new do
        described_class.new(
          concurrent_request,
          runner: runner,
          semaphore: semaphore,
          image_namespace: "worker-daemon-#{index}"
        ).resolve
      end
    end

    expect(threads.map(&:value)).to all(eq("syrus-devcontainer:#{spec.fingerprint.first(24)}"))
    expect(runners.sum(&:build_count)).to eq(2)
    expect(semaphore.keys.uniq.size).to eq(2)
  end

  it "translates devcontainer build paths into the Docker host namespace" do
    enable_devcontainer
    host_workspace = "/docker-host/workflows/123"
    ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "#{@workspace}=#{host_workspace}"
    spec = instance_double(
      ContainerExecution::DevcontainerSpec::Result,
      image: nil,
      source: ".devcontainer/devcontainer.json",
      revision: "b" * 40,
      fingerprint: "b" * 64,
      build: { "dockerfile" => "Dockerfile", "context" => ".." }
    )
    allow(ContainerExecution::DevcontainerSpec).to receive(:for_job).and_return(spec)
    runner = runner_returning(failure, failure, success)

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
      revision: "c" * 40,
      fingerprint: "c" * 64,
      build: { "dockerfile" => "Dockerfile", "context" => ".." }
    )
    allow(ContainerExecution::DevcontainerSpec).to receive(:for_job).and_return(spec)
    runner = runner_returning(failure)

    expect { described_class.new(request, runner: runner).resolve }
      .to raise_error(ContainerExecution::SeedImage::BuildError, /not visible to the Docker host/)
  end

  describe "with the Runtime Image Service available" do
    # One fake registry shared by every worker; each worker has its own
    # Docker runner and therefore its own image store.
    class FakeRuntimeImages
      attr_reader :published, :acquired

      def initialize
        @published = {}
        @acquired = []
      end

      def available? = true

      def find(source_ref:, **)
        @published[source_ref]
      end

      def publish_local(local_reference:, source_ref:, source_digest:, provenance:, **)
        @published[source_ref] = Struct.new(:locator, :digest, :provenance, :source_digest).new(
          "registry.test/syrus/devcontainer/repo-42@sha256:#{'1' * 64}", "sha256:#{'1' * 64}", provenance, source_digest
        )
      end

      def acquire(image)
        @acquired << image
        yield image.locator
      end
    end

    let(:images) { FakeRuntimeImages.new }
    let(:spec_result) do
      ContainerExecution::DevcontainerSpec::Result.new(
        config: { "build" => { "dockerfile" => "Dockerfile", "context" => ".." } },
        source: ".devcontainer/devcontainer.json", revision: "f" * 40
      )
    end
    let(:artifact) { { "config" => spec_result.config, "source" => spec_result.source, "revision" => spec_result.revision } }

    def worker(runner, semaphore: ConcurrentSemaphore.new)
      described_class.new(
        request(repository: instance_double(Repository, id: 42), workflow: instance_double(Workflow, artifact: artifact)),
        runner: runner, semaphore: semaphore, sleeper: ->(_) { Thread.pass }, images: images
      )
    end

    it "publishes the build and runs the digest, not a worker-local tag" do
      enable_devcontainer
      ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "#{@workspace}=#{@workspace}"
      runner = LocalImageRunner.new

      reference = worker(runner).resolve

      expect(reference).to eq("registry.test/syrus/devcontainer/repo-42@sha256:#{'1' * 64}")
      expect(reference).not_to include("syrus-devcontainer:")
      expect(runner.build_count).to eq(1)
      published = images.published.values.sole
      expect(published.provenance).to include("revision" => "f" * 40, "fingerprint" => spec_result.fingerprint)
      expect(images.published.keys.sole).to eq("rev-#{'f' * 40}-#{spec_result.fingerprint.first(24)}")
    end

    it "lets a second worker with an independent image store reuse the published image without building" do
      enable_devcontainer
      ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "#{@workspace}=#{@workspace}"
      builder = LocalImageRunner.new
      other = LocalImageRunner.new

      first = worker(builder).resolve
      second = worker(other).resolve

      expect(second).to eq(first)
      expect(builder.build_count).to eq(1)
      expect(other.build_count).to eq(0)
      expect(images.acquired.size).to eq(2)
    end

    it "keeps the image leased for the duration of the block" do
      enable_devcontainer
      ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "#{@workspace}=#{@workspace}"
      yielded = nil

      worker(LocalImageRunner.new).with_image { |reference| yielded = reference }

      expect(yielded).to start_with("registry.test/")
    end

    it "serializes builds across the fleet rather than per Docker daemon" do
      enable_devcontainer
      ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "#{@workspace}=#{@workspace}"
      semaphore = ConcurrentSemaphore.new

      worker(LocalImageRunner.new, semaphore: semaphore).resolve

      expect(semaphore.keys).to all(eq("devcontainer_build:fleet:42:#{'f' * 40}"))
    end
  end

  describe "externally declared images" do
    it "keeps the declared reference and records the immutable digest on the workflow" do
      enable_devcontainer
      workflow = instance_double(Workflow, artifact: {
        "config" => { "image" => "ruby:3.4" }, "source" => ".devcontainer.json", "revision" => "abc123"
      })
      allow(workflow).to receive(:set_artifact!)
      runner = double("command runner")
      allow(runner).to receive(:capture3).and_return(
        [ "", "", success ],
        [ %(["ruby@sha256:#{'9' * 64}"]), "", success ]
      )

      expect(described_class.new(request(workflow: workflow), runner: runner).resolve).to eq("ruby:3.4")
      expect(workflow).to have_received(:set_artifact!).with(
        described_class::RESOLUTION_ARTIFACT_KEY,
        { "reference" => "ruby:3.4", "digest" => "sha256:#{'9' * 64}", "source" => ".devcontainer.json", "revision" => "abc123" }
      )
    end
  end

  def enable_devcontainer
    ENV["SYRUS_CONTAINER_EXECUTION_DEVCONTAINER"] = "true"
  end

  def request(workflow: nil, repository: instance_double(Repository, id: 1))
    instance_double(
      Execution::Request,
      job: instance_double(Job, repository: repository),
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

  def success = SeedImageCommandStatus.new(true, 0)
  def failure = SeedImageCommandStatus.new(false, 1)

  class ConcurrentSemaphore
    attr_reader :keys

    def initialize
      @mutex = Mutex.new
      @held = Set.new
      @rejected = ConditionVariable.new
      @rejected_once = false
      @keys = []
    end

    def wait(lock)
      @mutex.synchronize do
        @keys << lock.concurrency_key
        if @held.include?(lock.concurrency_key)
          @rejected_once = true
          @rejected.broadcast
          false
        else
          @held << lock.concurrency_key
          true
        end
      end
    end

    def signal(lock)
      @mutex.synchronize { @held.delete(lock.concurrency_key) }
    end

    def wait_for_rejection
      @mutex.synchronize { @rejected.wait(@mutex) until @rejected_once }
    end
  end

  class ConcurrentRunner
    def initialize(semaphore, image_store)
      @semaphore = semaphore
      @image_store = image_store
    end

    def capture3(_docker, command, *)
      if command == "image"
        status = @image_store.built? ? success : failure
        [ "", "", status ]
      else
        @image_store.start_build
        @semaphore.wait_for_rejection
        @image_store.finish_build
        [ "", "", success ]
      end
    end

    private

    def success = SeedImageCommandStatus.new(true, 0)
    def failure = SeedImageCommandStatus.new(false, 1)
  end

  class ConcurrentImageStore
    attr_reader :build_count

    def initialize
      @mutex = Mutex.new
      @built = false
      @build_count = 0
    end

    def built?
      @mutex.synchronize { @built }
    end

    def start_build
      @mutex.synchronize { @build_count += 1 }
    end

    def finish_build
      @mutex.synchronize { @built = true }
    end
  end

  class LocalImageRunner
    attr_reader :build_count

    def initialize
      @built = false
      @build_count = 0
    end

    def capture3(_docker, command, *)
      if command == "image"
        [ "", "", @built ? success : failure ]
      else
        @build_count += 1
        @built = true
        [ "", "", success ]
      end
    end

    private

    def success = SeedImageCommandStatus.new(true, 0)
    def failure = SeedImageCommandStatus.new(false, 1)
  end
  # `signal` here is unrescued, so a build that succeeded still failed on its
  # way out when Solid Queue 1.7.2 began reading these off the lock to decide
  # which semaphore row to credit. Asserted against the real gem rather than
  # the injected fake, because the fake cannot break this.
  describe "the build lock as a Solid Queue semaphore subject" do
    let(:lock) { described_class::BuildLock.new("devcontainer_build:spec") }

    it "answers everything SolidQueue::Semaphore asks of a job" do
      %i[concurrency_key concurrency_limit concurrency_duration
         acquired_semaphore_id acquired_concurrency_limit].each do |message|
        expect(lock).to respond_to(message), "BuildLock must answer ##{message}"
      end
    end

    it "takes and gives back a real semaphore slot without raising" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!

      expect(SolidQueue::Semaphore.wait(lock)).to be_present
      expect { SolidQueue::Semaphore.signal(lock) }.not_to raise_error
      expect(SolidQueue::Semaphore.wait(described_class::BuildLock.new("devcontainer_build:spec")))
        .to be_present
    ensure
      clear_solid_queue_test_tables!
    end
  end
end
