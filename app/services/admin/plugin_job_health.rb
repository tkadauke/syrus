module Admin
  class PluginJobHealth
    def initialize
      @counts = Hash.new { |plugins, plugin| plugins[plugin] = Hash.new { |queues, queue| queues[queue] = { depth: 0, failed_count: 0 } } }
      collect(pending_counts, :depth)
      collect(failed_counts, :failed_count)
    rescue ActiveRecord::StatementInvalid
      @counts = {}
    end

    def for(plugin, default_queue: nil)
      queues = @counts.fetch(plugin.to_s, {})
      queue_names = (queues.keys + Array(default_queue)).uniq.sort
      {
        queue: queue_names.join(", "),
        depth: queues.sum { |_, counts| counts[:depth] },
        failed_count: queues.sum { |_, counts| counts[:failed_count] }
      }
    end

    def summaries
      @counts.flat_map do |plugin, queues|
        queues.map do |queue, counts|
          { plugin:, queue:, **counts }
        end
      end.sort_by { |row| [ row[:plugin], row[:queue] ] }
    end

    private

    def pending_counts
      SolidQueue::Job.where(finished_at: nil).where.missing(:failed_execution)
        .group("solid_queue_jobs.class_name", "solid_queue_jobs.queue_name").count
    end

    def failed_counts
      SolidQueue::FailedExecution.joins(:job).group("solid_queue_jobs.class_name", "solid_queue_jobs.queue_name").count
    end

    def collect(rows, field)
      rows.each do |(class_name, queue_name), count|
        plugin = plugin_for(class_name, queue_name)
        next unless plugin

        @counts[plugin][queue_name][field] += count
      end
    end

    def plugin_for(class_name, queue_name)
      job_class = class_name.safe_constantize
      owner = job_class.plugin_slug if job_class&.respond_to?(:plugin_slug)
      owner.presence || queue_name.to_s[/\Aplugin_(.+)\z/, 1]
    end
  end
end
