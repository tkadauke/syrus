module MysqlDbBrowser
  class WorkflowToolSet
    include Syrus::Host::McpToolSet
    include Syrus::Host::GatedToolSet

    gated_by plugin: MysqlDbBrowser, model: Syrus::Host::MysqlConnection, delegate_to: ChatToolSet
  end
end
