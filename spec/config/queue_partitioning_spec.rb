# frozen_string_literal: true

require "rails_helper"
require "erb"
require "yaml"

# The multi-node deployment splits queues across two worker configs selected per
# pod via SOLID_QUEUE_CONFIG, while single-host / Compose keeps running the full
# config/queue.yml on one worker. These invariants guard both properties:
#   - Compose safety: queue.yml must still cover EVERY queue on one worker.
#   - Clean split:    home ∪ compute must equal queue.yml's queues, with the
#                     heavy/search queues partitioned (no queue orphaned, none
#                     double-run across the two tiers).
#   - Resume affinity: every worker config must consume this pod's own
#                     resume-<worker-storage-key> queue.
RSpec.describe "queue partitioning" do
  ROOT = Rails.root

  # The app's full queue vocabulary. Sources of truth:
  #   :runs / :merges             — Workflows::*.queue_name (workflow templates)
  #   :chat / :videos / etc.      — queue_as on non-workflow ActiveJob classes.
  APP_QUEUES = %w[
    runs
    merges
    chat
    videos
    control_plane
    polling
    indexing
    cleanup
    low_priority_maintenance
    connectivity
  ].freeze

  # Where each non-resume queue must run in the multi-node split.
  HOME_QUEUES = %w[
    chat
    videos
    control_plane
    polling
    indexing
    cleanup
    low_priority_maintenance
    connectivity
  ].freeze
  COMPUTE_QUEUES = %w[runs merges].freeze

  def load_config(relative)
    raw = File.read(ROOT.join(relative))
    YAML.safe_load(ERB.new(raw).result, aliases: true, permitted_classes: [ Symbol ])
  end

  # All queue tokens (space-separated within each worker's "queues" string)
  # declared in the `default` section, split into resume vs the rest.
  def queues_for(relative)
    workers = Array(load_config(relative).dig("default", "workers"))
    # Each worker's `queues` is a YAML array (multi-queue) or a bare string
    # (single queue). Array() normalizes both to a clean token list — do NOT
    # split on whitespace, since a queue name never contains a space and a
    # space-joined string is itself the bug this spec guards against.
    tokens = workers.flat_map { |w| Array(w["queues"]).map(&:to_s) }
    resume, regular = tokens.partition { |q| q.start_with?("resume-") }
    { resume: resume, regular: regular }
  end

  it "declares every multi-queue worker as a YAML array, not a space/comma-joined string" do
    # Solid Queue 1.4 does not split a space- or comma-separated queue string:
    # `Array("resume-x runs")` is one literal phantom queue, so the worker
    # claims zero jobs. Every queue token must be one clean queue name.
    %w[config/queue.yml config/queue.home.yml config/queue.compute.yml].each do |config|
      load_config(config).each_value do |section|
        next unless section.is_a?(Hash)

        Array(section["workers"]).each do |worker|
          Array(worker["queues"]).each do |queue|
            expect(queue.to_s).not_to match(/[,\s]/),
              "#{config}: queue #{queue.inspect} must be one clean name — use a YAML array for multiple queues"
          end
        end
      end
    end
  end

  it "keeps queue.yml a complete single-worker config (Compose / single-host)" do
    expect(queues_for("config/queue.yml")[:regular].uniq).to match_array(APP_QUEUES)
  end

  it "does not leave job classes on queues no worker consumes" do
    job_files = Dir.glob(ROOT.join("app/jobs/**/*.rb").to_s)
    declarations = job_files.flat_map do |path|
      File.readlines(path).filter_map do |line|
        match = line.match(/\bqueue_as\s+:(\w+)/)
        next unless match

        [ path.delete_prefix("#{ROOT}/"), match[1] ]
      end
    end

    unknown = declarations.reject { |_path, queue| APP_QUEUES.include?(queue) }
    message = "job classes declare unconsumed queues: " \
              "#{unknown.map { |path, queue| "#{path} => #{queue}" }.join(", ")}"
    expect(unknown).to be_empty, message
  end

  it "routes only the search-bound + light queues to the home worker" do
    expect(queues_for("config/queue.home.yml")[:regular].uniq).to match_array(HOME_QUEUES)
  end

  it "routes only the heavy search-free queues to the compute worker" do
    expect(queues_for("config/queue.compute.yml")[:regular].uniq).to match_array(COMPUTE_QUEUES)
  end

  it "partitions every app queue across home and compute with no orphan or overlap" do
    home = queues_for("config/queue.home.yml")[:regular].uniq
    compute = queues_for("config/queue.compute.yml")[:regular].uniq

    expect(home & compute).to be_empty, "a queue is double-run across tiers: #{(home & compute).inspect}"
    expect((home | compute)).to match_array(APP_QUEUES)
  end

  it "gives every worker config this data root's resume queue" do
    expected = WorkerStorageIdentity.queue_name
    expect(expected).to start_with("resume-")

    %w[config/queue.yml config/queue.home.yml config/queue.compute.yml].each do |config|
      resume = queues_for(config)[:resume].uniq
      expect(resume).to eq([ expected ]),
        "#{config} must consume exactly its own resume queue, got #{resume.inspect}"
    end
  end
end
