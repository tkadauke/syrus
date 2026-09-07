require "mcp"

module Syrus
  module Plugin
    # Shared skeleton for a plugin's agentic MCP tool sets. mysql_db_browser
    # and k8s_cluster each independently built a ChatToolSet (a TOOL_CLASSES
    # registry, gated by the plugin being enabled plus an existence check on
    # the plugin's own connection model, dispatching by tool name with a
    # uniform "unknown tool"/rescue/log/error-Response shape) and a
    # WorkflowToolSet that gates the same way but forwards everything to that
    # ChatToolSet - k8s_cluster's own comments admit it was built by mirroring
    # mysql_db_browser file-by-file. This is the shape both pairs share,
    # extracted so a third gated-connection plugin doesn't have to hand-roll
    # it a third time.
    #
    # `admin_mysql` does not use this: it browses Syrus's own already-
    # configured DB connection, with no external connection model to gate on
    # at all - a different security shape entirely.
    #
    # A ChatToolSet includes this, configures the gate, and declares its own
    # TOOL_CLASSES:
    #
    #   class ChatToolSet
    #     include Syrus::Plugin::GatedToolSet
    #
    #     gated_by plugin: MysqlDbBrowser, model: MysqlConnection, label: "MySQL DB Browser"
    #
    #     TOOL_CLASSES = [ListConnectionsTool, ListDatabasesTool, ...].freeze
    #
    #     def self.available_for?(_chat_session, tier:)
    #       %i[essential deferred].include?(tier.to_sym) && gated?
    #     end
    #   end
    #
    # A WorkflowToolSet includes the same module, configures the same gate,
    # and points `delegate_to:` at that ChatToolSet instead of declaring its
    # own TOOL_CLASSES; the mixin then supplies `available_for?`,
    # `available_for_context?`, `tool_definitions`, and `handle` that gate on
    # the implement role and forward to the delegate:
    #
    #   class WorkflowToolSet
    #     include Syrus::Plugin::McpToolSet
    #     include Syrus::Plugin::GatedToolSet
    #
    #     gated_by plugin: MysqlDbBrowser, model: MysqlConnection, delegate_to: ChatToolSet
    #   end
    module GatedToolSet
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Configures the gate every method below relies on: `plugin` answers
        # `.enabled?`, `model` answers `.exists?`. `label` names this tool
        # set in "Unknown ... tool" error text (required for a ChatToolSet;
        # unused for a `delegate_to:` WorkflowToolSet, which never builds
        # that message itself). `delegate_to` turns this into a
        # WorkflowToolSet-shaped host: tool listing/dispatch forward to that
        # ChatToolSet instead of a local TOOL_CLASSES constant.
        def gated_by(plugin:, model:, label: nil, delegate_to: nil)
          @gate_plugin = plugin
          @gate_model = model
          @gate_label = label
          @gate_delegate = delegate_to
        end

        attr_reader :gate_plugin, :gate_model, :gate_label, :gate_delegate

        def gated?
          gate_plugin.enabled? && gate_model.exists?
        end

        def available_for?(*)
          gated?
        end

        def available_for_context?(context)
          workflow_implement_context?(context) && available_for?(context.repository)
        end

        def tool_classes
          const_get(:TOOL_CLASSES)
        end

        def find_tool_class(tool_name)
          tool_classes.find { |candidate| candidate.tool_name == tool_name.to_s }
        end

        def tool_definitions(tier: nil, context: nil)
          return [] if context && !workflow_implement_context?(context)
          return gate_delegate.tool_definitions(tier: :essential) if gate_delegate

          tool_classes.map do |klass|
            { name: klass.tool_name, description: klass.description_value, input_schema: klass.input_schema_value.to_h }
          end
        end

        def symbolize(params)
          (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
        end

        private

        def workflow_implement_context?(context)
          context.role == AgentRole::WORKFLOW_IMPLEMENT
        end
      end

      def handle(tool_name, params, server_context)
        return self.class.gate_delegate.new.handle(tool_name, params, server_context) if self.class.gate_delegate

        klass = self.class.find_tool_class(tool_name)
        return unknown_tool_response(tool_name) unless klass

        klass.call(**self.class.symbolize(params), server_context: server_context)
      rescue StandardError => e
        Rails.logger.error("[#{self.class.name}] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def unknown_tool_response(tool_name)
        MCP::Tool::Response.new([ { type: "text", text: "Unknown #{self.class.gate_label} tool: #{tool_name.inspect}" } ], error: true)
      end
    end
  end
end
