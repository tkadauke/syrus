module Syrus
  module Plugin
    # Shared authorization gate for agentic (workflow/chat MCP tool) access to
    # an externally-configured connection record (MysqlConnection,
    # KubernetesCluster, ...). Every agentic tool call names a connection id in
    # its params, and this is the single place that resolves it and enforces
    # that connection's own `agentic_access_enabled` flag - and, for
    # write-capable tools, its independent `allow_writes` flag - before any
    # tool touches the external system. There is no framework hook to do this
    # at manifest-build time (ChatToolSet/WorkflowToolSet#available_for? only
    # ever sees the surface, never an individual call's params) - so each
    # domain's AgenticAccess class calls into this concern, mirroring
    # Mcp::Tools::AuthorizationSupport's find_*! pattern for first-party
    # tools.
    #
    # `admin_mysql` intentionally does NOT use this concern: it browses
    # Syrus's own already-configured DB connection, with no external
    # credential model at all - a legitimately different security shape from
    # the agent-facing external connections this concern gates.
    #
    # Extend this into a class-level AgenticAccess (`extend
    # Syrus::Plugin::AgenticConnection`) and give it the domain's own error
    # classes plus the two naming pieces every message template below is
    # parameterized by:
    #   resource_name      - e.g. "MySQL connection" / "Kubernetes cluster",
    #                         used verbatim in the not-found message; its last
    #                         word (lowercased) is reused as the short noun in
    #                         the access/write-access messages.
    #   settings_location   - e.g. "DB Browser connection settings" / "K8s
    #                         Cluster connection settings", where an admin
    #                         goes to flip the flags.
    module AgenticConnection
      # Resolves `model_class` by `id`, raising `not_found_error` if missing
      # or `access_disabled_error` unless the record has opted into agentic
      # access.
      def find_agentic!(model_class, id, resource_name:, settings_location:, not_found_error:, access_disabled_error:)
        record = model_class.find_by(id: id)
        raise not_found_error, "#{resource_name} #{id.inspect} was not found." unless record

        unless record.agentic_access_enabled?
          raise access_disabled_error, "Agentic access is disabled for the \"#{record.label}\" #{agentic_kind(resource_name)}. " \
            "An admin must enable it from #{settings_location} before agents can query it."
        end

        record
      end

      # Same as find_agentic!, plus the stricter allow_writes? gate every
      # write-capable agentic tool needs: a record that passes agentic access
      # but hasn't independently opted into writes raises
      # `write_access_disabled_error` instead of the generic access-disabled
      # wording, which talks about read access.
      def find_agentic_with_write_access!(model_class, id, resource_name:, settings_location:, not_found_error:, access_disabled_error:, write_access_disabled_error:)
        record = find_agentic!(
          model_class, id,
          resource_name: resource_name, settings_location: settings_location,
          not_found_error: not_found_error, access_disabled_error: access_disabled_error
        )
        require_write_access!(record, resource_name: resource_name, settings_location: settings_location, write_access_disabled_error: write_access_disabled_error)
      end

      # Lower-level write gate for a record a caller already resolved via
      # find_agentic! earlier - e.g. MysqlDbBrowser::QueryExecutor, which is
      # handed an already-access-checked connection up front and only needs
      # the write gate once it has parsed the statement and knows it isn't
      # read-only. Deliberately does not re-check agentic_access_enabled?:
      # that gate already ran when the record was first resolved.
      def require_write_access!(record, resource_name:, settings_location:, write_access_disabled_error:)
        unless record.allow_writes?
          kind = agentic_kind(resource_name)
          raise write_access_disabled_error, "Write access is disabled for the \"#{record.label}\" #{kind}. " \
            "An admin must enable \"Allow writes\" for this #{kind} from #{settings_location} " \
            "before agents can run mutating actions against it."
        end

        record
      end

      private

      def agentic_kind(resource_name)
        resource_name.split.last.downcase
      end
    end
  end
end
