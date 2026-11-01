module SdlcPipeline
  class ChatJobStatusExtension
    include Syrus::Plugin::ChatJobStatusExtension
    def self.payload(chat_session:, jobs:)
      repositories = jobs.map(&:repository).compact.uniq(&:id).sort_by(&:slug)
      return {} if repositories.empty?

      filter = { "and" => [ { "field" => "associated_chat_id", "op" => "is", "value" => chat_session.id } ] }
      {
        actions: repositories.map do |repository|
          {
            id: "sdlc_pipeline.#{repository.id}", label_i18n_key: "sdlc_pipeline:chat_view_pipeline", repository_id: repository.id,
            repository_label: repository.slug,
            path: "/repositories/#{repository.id}/plugin/sdlc-pipeline?#{ { q: Filters::QueryParam.encode(filter) }.to_query }"
          }
        end
      }
    end
  end
end
