module MysqlDbBrowser
  class WorkflowToolSet
    include Syrus::Host::McpToolSet
    include Syrus::Host::GatedToolSet

    gated_by plugin: MysqlDbBrowser, model: MysqlConnection, delegate_to: ChatToolSet
  end
end
