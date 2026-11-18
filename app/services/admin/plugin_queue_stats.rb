module Admin
  class PluginQueueStats
    def self.call(manifests = Syrus::PluginRegistry.all_plugins)
      queue_names = manifests.to_h { |manifest| [ manifest.name, queue_name(manifest.name) ] }
      depths = SolidQueue::Job
        .left_joins(:failed_execution)
        .where(queue_name: queue_names.values, finished_at: nil)
        .where(solid_queue_failed_executions: { id: nil })
        .annotate("plugin_queue_stats")
        .group(:queue_name)
        .count
      failures = SolidQueue::FailedExecution.joins(:job)
        .where(solid_queue_jobs: { queue_name: queue_names.values })
        .annotate("plugin_queue_stats")
        .group("solid_queue_jobs.queue_name")
        .count

      queue_names.map do |plugin, queue|
        { plugin: plugin, queue_name: queue, depth: depths.fetch(queue, 0), failure_count: failures.fetch(queue, 0) }
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      queue_names.map do |plugin, queue|
        { plugin: plugin, queue_name: queue, depth: 0, failure_count: 0 }
      end
    end

    def self.queue_name(plugin_name)
      "plugin_#{plugin_name.to_s.parameterize(separator: "_")}"
    end
    private_class_method :queue_name
  end
end
