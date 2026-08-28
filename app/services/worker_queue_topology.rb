require "set"

# Introspects the active Solid Queue *worker* configuration for THIS
# process — the same precedent WorkerStorageIdentity sets for reading
# storage identity out of the active queue config, applied to queue
# membership instead. Lets code that only makes sense on the pod(s) actually
# consuming a specific queue (e.g. GitHistory::RelayServer, which must only
# start where RepositoryBareClone#sync! actually runs) gate on that directly,
# instead of on the coarser "this is *a* worker process" check — which is
# true for every tier in a split deployment (config/queue.home.yml vs
# config/queue.compute.yml), not just the one that consumes the queue in
# question.
#
# Reuses SolidQueue::Configuration itself to resolve the config file (honors
# SOLID_QUEUE_CONFIG, falls back to config/queue.yml) and the current
# Rails.env's worker list, rather than re-parsing the ERB/YAML independently.
class WorkerQueueTopology
  WILDCARD = "*"

  def self.consumes?(queue_name, config_file: nil)
    new(config_file: config_file).consumes?(queue_name)
  end

  def self.consumed_queues(config_file: nil)
    new(config_file: config_file).consumed_queues
  end

  def initialize(config_file: nil)
    @config_file = config_file
  end

  def consumes?(queue_name)
    consumed_queues.include?(WILDCARD) || consumed_queues.include?(queue_name.to_s)
  end

  def consumed_queues
    @consumed_queues ||= begin
      worker_processes.flat_map { |worker| Array(worker.attributes[:queues]).map(&:to_s) }.to_set
    rescue StandardError => e
      Rails.logger.warn("[WorkerQueueTopology] failed to resolve queue configuration: #{e.class}: #{e.message}")
      Set.new
    end
  end

  private

  # SolidQueue::Configuration#workers is private (only #configured_processes
  # is public); filter that down to just the :worker processes rather than
  # re-deriving worker-specific option merging ourselves.
  def worker_processes
    configuration.configured_processes.select { |process| process.kind == :worker }
  end

  def configuration
    @configuration ||= SolidQueue::Configuration.new(**configuration_options)
  end

  def configuration_options
    @config_file ? { config_file: @config_file } : {}
  end
end
