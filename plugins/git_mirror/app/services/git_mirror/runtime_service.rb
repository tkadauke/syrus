module GitMirror
  # The container this plugin asks Plugin Runtime to run. See
  # PluginRuntime::Service for the contract.
  class RuntimeService
    def self.service_name = Configuration::SERVICE_NAME

    def self.service_spec
      {
        image: Configuration.image,
        internal_port: 8080,
        volumes: [ { name: "data", mount_path: "/data" } ],
        env: { "GIT_MIRROR_TOKEN" => Configuration.token },
        healthcheck: { path: "/healthz" }
      }
    end

    # What Plugin Runtime's admin page shows under Details: how much the
    # mirror holds and how each repository is doing. Optional part of the
    # service contract (see PluginRuntime::Service).
    def self.service_details(endpoint:)
      stats = Stats.current(endpoint: endpoint) or return nil
      disk = stats.fetch("disk", {})
      repositories = stats.fetch("repositories", [])
      slugs = Repository.where(id: repositories.map { |repository| repository["id"] }).to_h { |r| [ r.id.to_s, r.slug ] }

      {
        summary: [
          { label_key: "git_mirror:details.repositories", value: repositories.size, format: "number" },
          { label_key: "git_mirror:details.mirror_size", value: disk["mirror_bytes"], format: "bytes" },
          { label_key: "git_mirror:details.disk_free", value: disk["free_bytes"], format: "bytes" },
          { label_key: "git_mirror:details.disk_total", value: disk["total_bytes"], format: "bytes" }
        ],
        table: {
          columns: [
            { key: "repository", label_key: "git_mirror:details.col_repository", format: "text" },
            { key: "size", label_key: "git_mirror:details.col_size", format: "bytes" },
            { key: "last_fetch_at", label_key: "git_mirror:details.col_last_fetch", format: "time" },
            { key: "last_maintenance_at", label_key: "git_mirror:details.col_last_maintenance", format: "time" },
            { key: "error", label_key: "git_mirror:details.col_error", format: "text" }
          ],
          rows: repositories.map do |repository|
            {
              repository: slugs.fetch(repository["id"].to_s, "##{repository['id']}"),
              size: repository["size_bytes"],
              last_fetch_at: repository["last_fetch_at"],
              last_maintenance_at: repository["last_maintenance_at"],
              error: repository["last_error"].presence
            }
          end.sort_by { |row| -row[:size].to_i }
        }
      }
    end
  end
end
