module SdlcPipeline
  module SmartFolders
    SUBJECT = "sdlc_pipeline"
    BUILTINS = [
      { key: "sdlc_pipeline_all", name: "All", visibility: :always, filter_bar_preset: false, filter: { "and" => [] } },
      { key: "sdlc_pipeline_mine", name: "Mine", visibility: :always, filter_bar_preset: false, filter: { "and" => [ { "field" => "owner_user_id", "op" => "is", "value" => "me" } ] } }
    ].freeze
    CHIPS = {
      "search" => "Filters::Chips::SdlcPipeline::Search",
      "associated_chat_id" => "Filters::Chips::SdlcPipeline::AssociatedChatId",
      "epic_id" => "Filters::Chips::Jobs::EpicId",
      "job_id" => "Filters::Chips::SdlcPipeline::JobId",
      "owner_user_id" => "Filters::Chips::Jobs::OwnerUserId"
    }.freeze

    module_function

    def install_into(scope)
      scope.effect("pipeline filter subject") { Filters.register_subject(name: SUBJECT, model: Job, chips: CHIPS) }
      scope.effect("pipeline smart folders") do
        SmartFolder.register_subject!(
          SUBJECT, builtins: BUILTINS, label: "Pipeline",
          effective_filter_contract: :smart_folder_resolution,
          path: ->(repository_id: nil, **query) { path(repository_id:, **query) }
        )
      end
    end

    def path(repository_id:, **query)
      base = repository_id ? "/repositories/#{repository_id}/plugin/sdlc-pipeline" : "/repositories"
      query.compact_blank.empty? ? base : "#{base}?#{query.compact_blank.to_query}"
    end
  end
end
