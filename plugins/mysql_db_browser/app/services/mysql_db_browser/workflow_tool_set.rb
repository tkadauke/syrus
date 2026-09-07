module MysqlDbBrowser
  class WorkflowToolSet
    include Syrus::Plugin::GatedToolSet::Workflow

    gated_by MysqlDbBrowser, model: MysqlConnection, chat_tool_set: ChatToolSet
  end
end
