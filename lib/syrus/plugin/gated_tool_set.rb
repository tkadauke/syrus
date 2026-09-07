require "mcp"

module Syrus
  module Plugin
    # Shared `ChatToolSet` skeleton for a plugin whose agentic tools are
    # gated per-connection rather than globally. `mysql_db_browser` and
    # `k8s_cluster` each hand-rolled an identical find-tool-class-by-name /
    # dispatch `#call` / rescue StandardError / log / error-`Response`
    # `#handle`, an `available_for?` that only checks the plugin is enabled,
    # the tier is agent-facing, and at least one connection record exists
    # (the real per-connection authorization check happens inside each
    # tool's own `#call` once it knows which connection id the agent named -
    # see `Syrus::Plugin::AgenticConnection`), and a byte-identical
    # `self.symbolize` params helper.
    #
    # Include into a `ChatToolSet` that defines its own `TOOL_CLASSES` array
    # and calls `gated_by`:
    #
    #   class ChatToolSet
    #     include Syrus::Plugin::GatedToolSet
    #
    #     TOOL_CLASSES = [ListClustersTool, ...].freeze
    #
    #     gated_by K8sCluster, model: KubernetesCluster, tool_set_label: "K8s Cluster"
    #   end
    #
    # See `Syrus::Plugin::GatedToolSet::Workflow` for the matching
    # `WorkflowToolSet` skeleton, which delegates straight to a gated
    # `ChatToolSet`.
    module GatedToolSet
      extend ActiveSupport::Concern

      class_methods do
        # plugin_module    - the plugin's top-level module, e.g. K8sCluster;
        #                    must respond to .enabled?
        # model            - the connection model class, e.g.
        #                    KubernetesCluster; must respond to .exists?
        # tool_set_label   - human name used in "Unknown <label> tool: ..."
        #                    error text and the Rails logger tag, e.g.
        #                    "K8s Cluster"
        def gated_by(plugin_module, model:, tool_set_label:)
          @gated_plugin_module = plugin_module
          @gated_model_class = model
          @gated_tool_set_label = tool_set_label
        end

        attr_reader :gated_plugin_module, :gated_model_class, :gated_tool_set_label

        def available_for?(_chat_session, tier:)
          gated_plugin_module.enabled? && %i[essential deferred].include?(tier.to_sym) && gated_model_class.exists?
        end

        def tool_definitions(tier:)
          self::TOOL_CLASSES.map do |klass|
            {
              name: klass.tool_name,
              description: klass.description_value,
              input_schema: klass.input_schema_value.to_h
            }
          end
        end

        def symbolize(params)
          (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
        end
      end

      def handle(tool_name, params, server_context)
        klass = self.class::TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
        unless klass
          return MCP::Tool::Response.new(
            [ { type: "text", text: "Unknown #{self.class.gated_tool_set_label} tool: #{tool_name.inspect}" } ],
            error: true
          )
        end

        klass.call(**self.class.symbolize(params), server_context: server_context)
      rescue StandardError => e
        Rails.logger.error("[#{self.class.name}] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      # Shared `WorkflowToolSet` skeleton pairing with `GatedToolSet`:
      # available only to the implement role, once the plugin is enabled and
      # a connection exists, and delegates both `tool_definitions` and
      # `#handle` to the plugin's gated `ChatToolSet`.
      #
      #   class WorkflowToolSet
      #     include Syrus::Plugin::GatedToolSet::Workflow
      #
      #     gated_by K8sCluster, model: KubernetesCluster, chat_tool_set: ChatToolSet
      #   end
      module Workflow
        extend ActiveSupport::Concern

        included do
          include Syrus::Plugin::McpToolSet
        end

        class_methods do
          # plugin_module  - same contract as GatedToolSet.gated_by
          # model          - same contract as GatedToolSet.gated_by
          # chat_tool_set  - the plugin's gated ChatToolSet class, e.g.
          #                  K8sCluster::ChatToolSet
          def gated_by(plugin_module, model:, chat_tool_set:)
            @gated_plugin_module = plugin_module
            @gated_model_class = model
            @gated_chat_tool_set = chat_tool_set
          end

          attr_reader :gated_plugin_module, :gated_model_class, :gated_chat_tool_set

          def available_for?(_repository)
            gated_plugin_module.enabled? && gated_model_class.exists?
          end

          def available_for_context?(context)
            context.role == AgentRole::WORKFLOW_IMPLEMENT && available_for?(context.repository)
          end

          def tool_definitions(context: nil)
            return [] if context && context.role != AgentRole::WORKFLOW_IMPLEMENT

            gated_chat_tool_set.tool_definitions(tier: :essential)
          end
        end

        def handle(tool_name, params, server_context)
          self.class.gated_chat_tool_set.new.handle(tool_name, params, server_context)
        end
      end
    end
  end
end
