module Admin
  class PluginQueuesSnapshot
    PREFIX = "plugin_"

    def self.call
      depths = SolidQueue::Job.where(finished_at: nil)
        .where("queue_name LIKE ? ESCAPE '!'", "#{SolidQueue::Job.sanitize_sql_like(PREFIX, '!')}%")
        .pluck(:queue_name)
        .tally
      records = PluginRecord.where(name: plugin_names(depths)).index_by(&:name)

      (plugin_names(depths) | records.keys).sort.map do |name|
        record = records[name]
        {
          plugin: name,
          queue_name: PluginJob.queue_name_for(name),
          depth: depths.fetch(PluginJob.queue_name_for(name), 0),
          failure_count: record&.plugin_job_failure_count.to_i,
          last_failed_at: record&.plugin_job_last_failed_at&.iso8601,
          last_error: record&.plugin_job_last_error
        }
      end
    end

    def self.plugin_names(depths)
      registered = Syrus::PluginRegistry.all_plugins.map(&:name)
      queued = depths.keys.filter_map { |queue| queue.delete_prefix(PREFIX) if queue.start_with?(PREFIX) }
      registered | queued
    end
    private_class_method :plugin_names
  end
end
