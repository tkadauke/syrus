module DesignDocs
  module SmartFolders
    SUBJECT = "design_doc"

    BUILTINS = [
      { key: "design_docs_mine", name: "My docs", visibility: :always, filter: { "and" => [ { "field" => "owner_user_id", "op" => "is", "value" => "me" } ] } },
      { key: "design_docs_review_requested", name: "Review requested", visibility: :when_present, filter: { "and" => [ { "field" => "owner_user_id", "op" => "is", "value" => "me" }, { "field" => "pending_suggestions", "op" => "is_true", "value" => nil } ] } },
      { key: "design_docs_open_comments", name: "Open comments", visibility: :when_present, filter: { "and" => [ { "field" => "open_comments", "op" => "is_true", "value" => nil } ] } },
      { key: "design_docs_pending_suggestions", name: "Pending suggestions", visibility: :when_present, filter: { "and" => [ { "field" => "pending_suggestions", "op" => "is_true", "value" => nil } ] } },
      { key: "design_docs_recently_updated", name: "Recently updated", visibility: :always, filter: { "and" => [ { "field" => "updated_at", "op" => "within_last", "value" => { "n" => 30, "unit" => "days" } } ] } },
      { key: "design_docs_archived", name: "Archived", visibility: :on_demand, filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "archived" } ] } }
    ].freeze

    CHIPS = {
      "repository_id" => "Filters::Chips::DesignDocs::RepositoryId",
      "owner_user_id" => "Filters::Chips::DesignDocs::OwnerUserId",
      "state" => "Filters::Chips::DesignDocs::State",
      "visibility" => "Filters::Chips::DesignDocs::Visibility",
      "title" => "Filters::Chips::DesignDocs::Title",
      "updated_at" => "Filters::Chips::UpdatedAt",
      "open_comments" => "Filters::Chips::DesignDocs::OpenComments",
      "pending_suggestions" => "Filters::Chips::DesignDocs::PendingSuggestions"
    }.freeze

    module_function

    def register!
      Filters.register_subject(name: SUBJECT, model: DesignDoc, chips: CHIPS)
      ::SmartFolder.register_subject!(
        SUBJECT,
        builtins: BUILTINS,
        label: "Design Docs",
        path: ->(**query) { path(**query) }
      )
    end

    def path(**query)
      params = query.compact_blank
      params.empty? ? "/design_docs" : "/design_docs?#{params.to_query}"
    end
  end
end
