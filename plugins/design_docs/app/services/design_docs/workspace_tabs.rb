module DesignDocs
  class WorkspaceTabs
    include Syrus::Plugin::WorkspaceTab

    def self.workspace_tabs(chat_session = nil)
      data = workspace_data(chat_session)
      docs = data.fetch(:design_docs, [])
      return [ tab_payload(data:) ] if docs.length <= 1

      docs.map.with_index do |doc, index|
        tab_payload(
          id: "design_docs.chat.#{doc.fetch(:id)}",
          label: doc.fetch(:display_id),
          order: 20 + index,
          data: data.merge(selected_design_doc_id: doc.fetch(:id))
        )
      end
    end

    def self.tab_payload(id: "design_docs.chat", label: "Design Docs", order: 20, data:)
      selected_id = data[:selected_design_doc_id] || data.fetch(:design_doc_ids, []).first
      {
        id: id,
        label: label,
        label_key: label == "Design Docs" ? "design_docs:tab_design_docs" : nil,
        component: "design_docs/WorkspaceDesignDocs",
        order: order,
        closable: true,
        data: data.merge(selected_design_doc_id: selected_id)
      }
    end

    def self.workspace_data(chat_session)
      return {
        design_doc_ids: [],
        selected_design_doc_id: nil,
        originated_design_doc_ids: [],
        attached_design_doc_ids: [],
        design_docs: []
      } unless chat_session

      docs = visible_design_docs_for(chat_session)
        .includes(:owner_user, :current_version, :repositories)
        .newest_first
        .to_a
      originated_ids = docs.select { |doc| doc.origin_chat_session_id == chat_session.id }.map(&:id)
      attached_ids = docs.map(&:id) - originated_ids

      {
        design_doc_ids: docs.map(&:id),
        selected_design_doc_id: docs.first&.id,
        originated_design_doc_ids: originated_ids,
        attached_design_doc_ids: attached_ids,
        design_docs: docs.map { |doc| DesignDocs::Serializer.summary(doc) }
      }
    end

    def self.available_for?(chat_session)
      return false unless chat_session

      originated_design_docs_for(chat_session).exists? || visible_referenced_design_doc_exists?(chat_session)
    end

    def self.visible_design_docs_for(chat_session)
      visible = DesignDoc.visible_to(chat_session.user)
      referenced_ids = referenced_design_doc_ids(chat_session)

      visible_originated_design_docs_for(chat_session, visible:)
        .or(visible.where(id: referenced_ids))
    end

    def self.originated_design_docs_for(chat_session)
      visible_originated_design_docs_for(chat_session, visible: DesignDoc.visible_to(chat_session.user))
    end

    def self.visible_originated_design_docs_for(chat_session, visible:)
      visible.where(origin_chat_session_id: chat_session.id)
    end

    def self.visible_referenced_design_doc_exists?(chat_session)
      referenced_ids = referenced_design_doc_ids(chat_session)
      return false if referenced_ids.empty?

      DesignDoc.visible_to(chat_session.user).where(id: referenced_ids).exists?
    end

    def self.referenced_design_doc_ids(chat_session)
      chat_session.messages
                  .active
                  .where("CAST(content AS CHAR) LIKE ?", "%DOC-%")
                  .find_each.with_object([]) do |message, ids|
        extract_doc_refs(message.content).each { |id| ids << id }
      end.uniq
    end

    def self.extract_doc_refs(value)
      case value
      when String
        value.scan(/\bDOC-(\d+)\b/i).flatten.map(&:to_i)
      when Hash
        value.values.flat_map { |entry| extract_doc_refs(entry) }
      when Array
        value.flat_map { |entry| extract_doc_refs(entry) }
      else
        []
      end
    end
  end
end
