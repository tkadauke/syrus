module DesignDocs
  class WorkspaceTabs
    include Syrus::Plugin::WorkspaceTab

    def self.workspace_tabs
      [
        {
          id: "design_docs.chat",
          label: "Design Docs",
          label_key: "design_docs:tab_design_docs",
          component: "design_docs/WorkspaceDesignDocs",
          order: 20,
          closable: true
        }
      ]
    end

    def self.available_for?(chat_session)
      DesignDoc.visible_to(chat_session.user).where(origin_chat_session_id: chat_session.id).exists?
    end
  end
end
