module DesignDocs
  class SearchSource
    TABLE_SQL = <<~SQL.freeze
      CREATE VIRTUAL TABLE IF NOT EXISTS design_doc_fts
      USING fts5(
        display_id,
        title,
        body,
        preview_text,
        repository_text,
        owner_text,
        collaborator_text,
        design_doc_id UNINDEXED,
        owner_user_id UNINDEXED,
        visibility UNINDEXED,
        state UNINDEXED,
        created_at UNINDEXED,
        updated_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL

    def self.search_tables = { "design_doc_fts" => TABLE_SQL }
    def self.backfill_search_table(_name) = SearchIndex.rebuild!
    def self.rebuild_search_table(name) = backfill_search_table(name)

    def self.search_type = "design_doc"
    def self.search_type_label = "Design Docs"
    def self.filter_subject = DesignDocs::SmartFolders::SUBJECT
    def self.row_id_key = :design_doc_id

    def self.search_rows(query:, user:, limit:)
      SearchIndex.search(query, user: user, limit: limit)
    end

    def self.filtered_scope(ids:, tree:, user:)
      DesignDocs::Filter
        .from_tree(tree, user: user)
        .apply(DesignDocs::DesignDoc.visible_to(user).where(id: ids))
    end

    def self.result_json(row:, user:)
      design_doc = DesignDocs::DesignDoc
        .visible_to(user)
        .includes(:owner_user, :current_version, :repositories)
        .find_by(id: row.fetch(:design_doc_id).to_i)
      return nil unless design_doc

      repository = design_doc.repositories.first
      {
        type: search_type,
        id: design_doc.id,
        slug: design_doc.display_id,
        title: design_doc.title,
        snippet: row.fetch(:snippet),
        rank: row.fetch(:rank),
        path: "/design_docs/#{design_doc.id}",
        state: design_doc.state,
        repository_slug: repository&.slug,
        created_at: design_doc.created_at&.iso8601,
        updated_at: design_doc.updated_at&.iso8601,
        visibility: design_doc.visibility,
        owner: user_json(design_doc.owner_user),
        current_version_number: design_doc.current_version&.version_number
      }
    end

    def self.enabled?
      Syrus::PluginRegistry.providers_for("global_search:source").include?(self)
    end

    def self.user_json(user)
      return nil unless user

      {
        id: user.id,
        name: user.display_name,
        email_address: user.email_address
      }
    end
  end
end
