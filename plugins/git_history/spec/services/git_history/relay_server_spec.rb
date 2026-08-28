require "rails_helper"
require "rack/mock"
require "tmpdir"
require "fileutils"

RSpec.describe GitHistory::RelayServer do
  let(:server) { described_class.new }
  let(:syrus_data_root) { Pathname.new(Dir.mktmpdir("syrus-data")) }
  let(:origin_dir) { Pathname.new(Dir.mktmpdir("syrus-origin")) }
  let(:repository) { Factories.repository(default_branch: "main") }

  before do
    ENV["SYRUS_DATA_ROOT"] = syrus_data_root.to_s
    FileUtils.mkdir_p(origin_dir)
    `git init -b main #{origin_dir} 2>&1`
    `git -C #{origin_dir} config user.email "test@example.com" 2>&1`
    `git -C #{origin_dir} config user.name "Test" 2>&1`
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(syrus_data_root)
    FileUtils.rm_rf(origin_dir)
  end

  def commit!(message)
    `touch #{origin_dir}/file-#{SecureRandom.hex(4)}.txt`
    `git -C #{origin_dir} add . 2>&1`
    `git -C #{origin_dir} commit -m "#{message}" 2>&1`
    `git -C #{origin_dir} rev-parse HEAD 2>&1`.strip
  end

  def bare_clone!
    path = RepositoryBareClone.path_for(repository)
    FileUtils.mkdir_p(path.dirname)
    output = `git clone --bare #{origin_dir} #{path} 2>&1`
    raise "bare clone failed: #{output}" unless $?.success?
  end

  def call(path)
    server.call(Rack::MockRequest.env_for(path))
  end

  def json_body(response)
    JSON.parse(response[2].first)
  end

  describe "GET /repositories/:id/available" do
    it "is false when the bare clone has not been synced" do
      response = call("/repositories/#{repository.id}/available")

      expect(response[0]).to eq(200)
      expect(json_body(response)).to eq("available" => false)
    end

    it "is true once the bare clone exists on disk" do
      commit!("initial")
      bare_clone!

      response = call("/repositories/#{repository.id}/available")

      expect(response[0]).to eq(200)
      expect(json_body(response)).to eq("available" => true)
    end

    it "returns 404 for an unknown repository id" do
      response = call("/repositories/999999/available")

      expect(response[0]).to eq(404)
      expect(json_body(response)).to eq("error" => "not_found")
    end
  end

  describe "GET /repositories/:id/commits" do
    it "returns commits newest-first with has_more" do
      commit!("first")
      commit!("second")
      commit!("third")
      bare_clone!

      response = call("/repositories/#{repository.id}/commits?limit=2")

      expect(response[0]).to eq(200)
      body = json_body(response)
      expect(body["entries"].map { |e| e["subject"] }).to eq([ "third", "second" ])
      expect(body["has_more"]).to be true
      expect(body["entries"].first).to include(
        "sha" => a_string_matching(/\A[0-9a-f]{40}\z/),
        "author_name" => "Test",
        "author_email" => "test@example.com"
      )
    end

    it "continues from a cursor" do
      sha1 = commit!("first")
      commit!("second")
      bare_clone!

      first_page = json_body(call("/repositories/#{repository.id}/commits?limit=1"))
      cursor = first_page["entries"].first["sha"]

      second_page = json_body(call("/repositories/#{repository.id}/commits?cursor=#{cursor}&limit=1"))

      expect(second_page["entries"].map { |e| e["sha"] }).to eq([ sha1 ])
      expect(second_page["has_more"]).to be false
    end

    it "returns an empty page when the bare clone has not been synced" do
      response = call("/repositories/#{repository.id}/commits?limit=10")

      expect(response[0]).to eq(200)
      expect(json_body(response)).to eq("entries" => [], "has_more" => false)
    end

    it "returns 404 for an unknown repository id" do
      response = call("/repositories/999999/commits?limit=10")

      expect(response[0]).to eq(404)
      expect(json_body(response)).to eq("error" => "not_found")
    end
  end

  it "returns 404 for paths that don't match a known route" do
    response = call("/nope")

    expect(response[0]).to eq(404)
  end

  describe ".ensure_running!" do
    after do
      described_class.instance_variable_set(:@instance, nil)
      described_class.remove_instance_variable(:@polling_queue_consumer) if described_class.instance_variable_defined?(:@polling_queue_consumer)
    end

    it "starts the relay when this process consumes the polling queue" do
      allow(WorkerQueueTopology).to receive(:consumes?).with(described_class::POLLING_QUEUE).and_return(true)
      fake_instance = instance_double(described_class)
      allow(described_class).to receive(:start).and_return(fake_instance)

      result = described_class.ensure_running!

      expect(result).to eq(fake_instance)
      expect(described_class).to have_received(:start)
    end

    it "does not start the relay when this process does not consume the polling queue" do
      allow(WorkerQueueTopology).to receive(:consumes?).with(described_class::POLLING_QUEUE).and_return(false)
      allow(described_class).to receive(:start)

      result = described_class.ensure_running!

      expect(result).to be_nil
      expect(described_class).not_to have_received(:start)
    end

    it "does not re-derive queue topology once already running" do
      described_class.instance_variable_set(:@instance, instance_double(described_class))
      allow(WorkerQueueTopology).to receive(:consumes?)

      described_class.ensure_running!

      expect(WorkerQueueTopology).not_to have_received(:consumes?)
    end

    it "memoizes the polling-queue-consumer check instead of re-deriving it on every call" do
      allow(WorkerQueueTopology).to receive(:consumes?).with(described_class::POLLING_QUEUE).and_return(false)
      allow(described_class).to receive(:start)

      described_class.ensure_running!
      described_class.ensure_running!

      expect(WorkerQueueTopology).to have_received(:consumes?).once
    end
  end
end
