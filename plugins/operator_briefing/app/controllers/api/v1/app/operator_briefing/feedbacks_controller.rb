module Api
  module V1
    module App
      module OperatorBriefing
        class FeedbacksController < BaseController
          def create
            feedback = ::OperatorBriefing::Feedback.create!(
              user: Current.user,
              briefing: briefing,
              briefing_item: briefing_item,
              sentiment: feedback_params[:sentiment].presence,
              note: feedback_params[:note].presence
            )

            render json: {
              feedback: feedback_payload(feedback),
              briefing: ::OperatorBriefing::Payload.new(user: Current.user).as_json
            }, status: :created
          end

          private

          def feedback_params
            params.require(:feedback).permit(:briefing_id, :briefing_item_id, :sentiment, :note)
          end

          def briefing
            return @briefing if defined?(@briefing)

            @briefing = if feedback_params[:briefing_id].present?
              ::OperatorBriefing::Briefing.where(owner_user: Current.user).find(feedback_params[:briefing_id])
            elsif briefing_item
              briefing_item.briefing
            end
          end

          def briefing_item
            return @briefing_item if defined?(@briefing_item)

            @briefing_item = if feedback_params[:briefing_item_id].present?
              ::OperatorBriefing::BriefingItem.joins(:briefing)
                .where(operator_briefing_briefings: { owner_user_id: Current.user.id })
                .find(feedback_params[:briefing_item_id])
            end
          end

          def feedback_payload(feedback)
            {
              id: feedback.id,
              memory_entry_id: feedback.memory_entry_id,
              sentiment: feedback.sentiment,
              note: feedback.note
            }
          end
        end
      end
    end
  end
end
