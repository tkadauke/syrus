module Coworkers
  class ChatToolSet
    include Syrus::Plugin::ChatMcpToolSet

    TOOLS = [
      McpTools::ListCoworkersTool,
      McpTools::ListCoworkerGrantsTool,
      McpTools::ReadCoworkerTool,
      McpTools::ProposeCoworkerTool,
      McpTools::ProposeGrantEscalationTool
    ].freeze
    WORKSPACE_TOOLS = [
      WorkspaceFileTools::Write,
      WorkspaceFileTools::Edit,
      WorkspaceFileTools::Move,
      WorkspaceFileTools::Delete
    ].freeze
    TOOL_CLASSES = ([ MessageCoworkerTool, ReplyInChatThreadTool, ManageScheduleTool, SpawnChatTool, SpawnSyrusChatTool ] + WORKSPACE_TOOLS).freeze

    def self.coworker_grants
      [
        {
          name: "workspace.files", label: "Update coworker workspace files",
          description: "Create, exactly edit, move, and delete files inside the coworker's isolated workspace.",
          default_policy: "auto", maximum_policy: "auto", tools: WORKSPACE_TOOLS.map(&:tool_name),
          scope_options_callback: nil, scope_label_callback: nil, valid_scope_callback: nil
        },
        {
          name: "coworker.message", label: "Message coworkers",
          description: "Send bounded messages to another active coworker.",
          default_policy: "confirm", maximum_policy: "auto", tools: [ MessageCoworkerTool.tool_name ],
          scope_options_callback: nil, scope_label_callback: nil, valid_scope_callback: nil
        },
        {
          name: "schedule.manage_self", label: "Manage own schedule",
          description: "Create and manage the coworker's own recurring work.",
          default_policy: "confirm", maximum_policy: "auto", tools: [ ManageScheduleTool.tool_name ],
          scope_options_callback: nil, scope_label_callback: nil, valid_scope_callback: nil
        },
        {
          name: "coworker.spawn_chat",
          label: "Spawn side chats",
          description: "Create another side chat for this coworker, subject to per-run and daily caps.",
          default_policy: "confirm",
          maximum_policy: "confirm",
          tools: [ SpawnChatTool.tool_name ],
          scope_options_callback: nil,
          scope_label_callback: nil,
          valid_scope_callback: nil
        },
        {
          name: "syrus.spawn_chat",
          label: "Start Syrus engineering chats",
          description: "Create an ordinary planner chat for the owner in a selected accessible repository, subject to per-run and daily caps.",
          default_policy: "confirm",
          maximum_policy: "confirm",
          tools: [ SpawnSyrusChatTool.tool_name ],
          scope_options_callback: ->(user:) { Mcp::Tools::CoworkerRepositoryAccess.scope_options(user:) },
          scope_label_callback: ->(value) { Mcp::Tools::CoworkerRepositoryAccess.scope_label(value) },
          valid_scope_callback: ->(value, user:) { Mcp::Tools::CoworkerRepositoryAccess.valid_scope?(value, user:) }
        }
      ]
    end

    # Explicit descriptors so each default policy is justified by classified
    # effects (see Permissions::CoworkerDefaultPolicy), never inherited.
    def self.coworker_descriptor(klass)
      name = klass.tool_name
      if WORKSPACE_TOOLS.include?(klass)
        Permissions::CoworkerActions.descriptor(tool_name: name, family: "workspace.files", effects: %i[isolated_workspace_write],
          risk: :low, default: :allow, maximum_autonomy: :invocation)
      elsif klass == ReplyInChatThreadTool
        Permissions::CoworkerActions.descriptor(tool_name: name, family: "chat.reply_owner_thread", effects: %i[internal_write],
          risk: :low, default: :allow, benign_internal: :owner_interaction)
      elsif klass == ManageScheduleTool
        Permissions::CoworkerActions.descriptor(tool_name: name, family: "schedule.manage_self",
          effects: %i[internal_write persistent_autonomy], risk: :medium, default: :ask)
      elsif klass.respond_to?(:coworker_descriptor)
        klass.coworker_descriptor
      else
        Permissions::CoworkerActions.descriptor(tool_name: name, family: "coworker.message",
          effects: %i[internal_write communication], risk: :medium, default: :ask)
      end
    end

    def self.available_for?(chat_session, tier:)
      Coworkers.enabled? && tier.to_sym == :deferred && !Coworkers::Chat.exists?(chat_session_id: chat_session.id)
    end

    def self.coworker_specific_availability? = true

    def self.available_for_coworker?(_chat_session, tier:)
      Coworkers.enabled? && tier.to_sym == :essential
    end

    def self.tool_definitions(tier:)
      if tier.nil? || tier.to_sym == :essential
        return TOOL_CLASSES.map do |klass|
          workspace_tool = WORKSPACE_TOOLS.include?(klass)
          {
            name: klass.tool_name,
            description: klass.description_value,
            input_schema: klass.input_schema_value.to_h,
            coworker_safe: true,
            capability: if workspace_tool
              "workspace.files"
                        elsif klass == ReplyInChatThreadTool
              "chat.reply_owner_thread"
                        elsif klass == ManageScheduleTool
              "schedule.manage_self"
                        elsif klass.respond_to?(:coworker_capability)
              klass.coworker_capability
                        else
              "coworker.message"
                        end,
            # Spawn tools create the owner's real confirmation card themselves;
            # bypassing the generic gate prevents a second approval card.
            ungated: klass == ReplyInChatThreadTool,
            approval_effect: klass.respond_to?(:coworker_approval_effect?) && klass.coworker_approval_effect?,
            mutation: true,
            capability_descriptor: coworker_descriptor(klass)
          }
        end
      end

      return [] unless tier.to_sym == :deferred

      TOOLS.map { |tool| { name: tool.tool_name, description: tool.description_value, input_schema: tool.input_schema_value.to_h } }
    end

    def handle(tool_name, params, server_context)
      tool = TOOLS.find { |candidate| candidate.tool_name == tool_name.to_s }
      return tool.call(**(params || {}).symbolize_keys, server_context: server_context) if tool

      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown coworker tool: #{tool_name.inspect}") unless klass

      klass.call(**symbolize(params), server_context: server_context)
    end

    private

    def symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
