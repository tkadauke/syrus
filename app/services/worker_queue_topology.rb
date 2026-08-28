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

  # Whether a raw list of configured queue names — in whatever shape Solid
  # Queue itself stores/accepts them, e.g. worker `queues:` config or
  # SolidQueue::Process#metadata["queues"] — covers a given queue. Mirrors
  # SolidQueue::QueueSelector's own matching (`"*"` = every queue, `"foo*"` =
  # prefix match, otherwise exact) so every caller in this codebase agrees on
  # wildcard semantics instead of each re-implementing "does this list cover
  # that queue" against raw queue-name strings independently.
  def self.queues_include?(queues, queue_name)
    queues = Array(queues).map(&:to_s)
    queue_name = queue_name.to_s

    return true if queues.include?(WILDCARD)
    return true if queues.include?(queue_name)

    queues.any? { |queue| queue.end_with?(WILDCARD) && queue_name.start_with?(queue.delete_suffix(WILDCARD)) }
  end

  def initialize(config_file: nil)
    @config_file = config_file
  end

  def consumes?(queue_name)
    self.class.queues_include?(consumed_queues, queue_name)
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
