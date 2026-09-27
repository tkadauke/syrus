module Api
  module V1
    module App
      module OperatorBriefing
        class TopicsController < BaseController
          def show
            topic = ::OperatorBriefing::BriefingTopic
              .where(repository_id: Repository.accessible_repository_ids_for(Current.user))
              .find(params[:id])
            render json: topic_payload(topic)
          end

          private

          def topic_payload(topic)
            revisions = topic.revisions.includes(:briefing, :workflow).order(revision_number: :desc, id: :desc)
            {
              id: topic.id,
              slug: topic.slug,
              title: topic.title,
              repository: {
                id: topic.repository.id,
                slug: topic.repository.slug,
                path: "/repositories/#{topic.repository.id}"
              },
              revisions: revisions.map do |revision|
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
              end
            }
          end
        end
      end
    end
  end
end
