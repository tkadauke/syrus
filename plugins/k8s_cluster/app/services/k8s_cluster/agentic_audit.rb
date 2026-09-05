module K8sCluster
  # Structured audit line for every agentic (workflow/chat MCP tool) call
  # against a cluster - cluster id, tool name, params, and whether the call
  # resolved or errored, same spirit as the JobLog audit lines other MCP
  # tool submissions leave behind. This logs rather than persisting to a DB
  # table: JobLog itself requires a Run, but agentic k8s calls can equally
  # come from a chat session (no Run at all), and unlike
  # MysqlDbBrowser::QueryExecutor#audit! there is no per-cluster query text
  # to keep an auditable record of - only which tool ran with which
  # arguments. Deliberately never logs the raw result payload (pod logs,
  # full manifests) - only its size - so this audit trail can't become a
  # second, un-redacted copy of cluster data sitting in the Rails log. The
  # one exception is the small, curated `before`/`after` summary a write
  # tool's result carries (replica counts, restart timestamps, schedulable
  # state) - never a full object - which write resource-service methods
  # (Deployments#scale, #restart_rollout, Pods#delete, Nodes#set_cordon)
  # include precisely so this line can show the mutation's effect.
  class AgenticAudit
    def self.log!(cluster_id:, tool_name:, params:, result: nil, error: nil)
      entry = {
        event: "k8s_cluster_agentic_call",
        cluster_id: cluster_id,
        tool: tool_name,
        params: params
      }

      if error
        entry[:outcome] = "error"
        entry[:error] = "#{error.class}: #{error.message}"
      else
        entry[:outcome] = "success"
        entry[:result_bytesize] = result.to_json.bytesize
        if result.is_a?(Hash) && (result.key?(:before) || result.key?(:after))
          entry[:before] = result[:before]
          entry[:after] = result[:after]
        end
      end

      Rails.logger.info("[K8sCluster::AgenticAudit] #{entry.to_json}")
    rescue StandardError => e
      Rails.logger.error("K8sCluster::AgenticAudit log failed: #{e.class}: #{e.message}")
    end
  end
end
