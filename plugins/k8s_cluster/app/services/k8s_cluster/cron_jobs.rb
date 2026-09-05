module K8sCluster
  class CronJobs < ResourceService
    MAX_CRON_JOBS = 1_000

    def list(namespace: nil)
      with_client(api_client.batch) do |client|
        items = client.get_cron_jobs(namespace_scope(namespace)).fetch("items", [])

        {
          available: true,
          generated_at: Time.current.iso8601,
          truncated: items.length > MAX_CRON_JOBS,
          cron_jobs: items.first(MAX_CRON_JOBS).map { |item| summary(item) }
        }
      end
    end

    def describe(name, namespace:)
      with_client(api_client.batch) do |client|
        { available: true, generated_at: Time.current.iso8601, cron_job: client.get_cron_job(name, namespace) }
      end
    end

    private

    def summary(item)
      {
        name: item.dig("metadata", "name"),
        namespace: item.dig("metadata", "namespace"),
        schedule: item.dig("spec", "schedule"),
        suspended: !!item.dig("spec", "suspend"),
        active_count: (item.dig("status", "active") || []).length,
        last_schedule_time: item.dig("status", "lastScheduleTime"),
        created_at: item.dig("metadata", "creationTimestamp")
      }
    end
  end
end
