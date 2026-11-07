module Api
  module V1
    module App
      module OperatorBriefing
        class TopicsController < BaseController
          REVISION_LIMIT = 3

          def show
            topic = ::OperatorBriefing::BriefingTopic
              .where(repository_id: Repository.accessible_repository_ids_for(Current.user))
              .find(params[:id])
            render json: topic_payload(topic)
          end

          private

          def topic_payload(topic)
            revisions = topic.revisions.includes(:briefing, :workflow).order(revision_number: :desc, id: :desc)
            revisions = revisions.where("revision_number < ?", cursor) if cursor
            page = revisions.limit(REVISION_LIMIT + 1).to_a
            next_revision = page.pop if page.length > REVISION_LIMIT
            {
              id: topic.id,
              slug: topic.slug,
              title: topic.title,
              repository: {
                id: topic.repository.id,
                slug: topic.repository.slug,
                path: "/repositories/#{topic.repository.id}"
              },
              revisions: page.map do |revision|
                {
                  id: revision.id,
                  revision_number: revision.revision_number,
                  generated_at: revision.generated_at&.iso8601,
                  narrative: revision.narrative,
                  findings: revision.findings,
                  references: revision.references,
                  briefing_id: revision.briefing_id,
                  workflow_id: revision.workflow_id
                }
              end,
              next_cursor: next_revision && page.last.revision_number
            }
          end

          def cursor
            value = params[:cursor].to_i
            value.positive? ? value : nil
          end
        end
      end
    end
  end
end
