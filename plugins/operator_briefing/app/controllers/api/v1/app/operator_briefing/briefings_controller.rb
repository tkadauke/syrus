module Api
  module V1
    module App
      module OperatorBriefing
        class BriefingsController < BaseController
          include ChatSessionLifecycle

          def show
            render json: ::OperatorBriefing::Payload.new(user: Current.user).as_json
          end

          def regenerate
            repository = Repository.where(id: Repository.accessible_repository_ids_for(Current.user)).find(params[:repository_id])
            ::OperatorBriefing::BriefingSubscription.find_or_create_by!(user: Current.user, repository: repository)
            ::OperatorBriefing::Generator.generate!(user: Current.user, repository: repository, mode: :on_demand)

            render json: ::OperatorBriefing::Payload.new(user: Current.user).as_json
          end

          def dive
            current_briefing = briefing
            return render_error("briefing_archived", "Only the current live briefing can start a dive.", status: :unprocessable_content) unless current_briefing.live?

            result = WorkUnits::Launcher.create_and_start!(
              kind: "briefing_dive",
              job: current_briefing.job,
              artifacts: {
                "briefing_dive_context" => {
                  "briefing_id" => current_briefing.id,
                  "selected_text" => dive_params[:selected_text].to_s.truncate(1_000),
                  "prompt" => dive_params[:prompt].to_s.truncate(2_000),
                  "evidence" => plain_json(dive_params[:evidence] || [])
                }
              }
            )

            render json: {
              workflow_id: result.workflow.id,
              status: result.status,
              briefing: ::OperatorBriefing::Payload.new(user: Current.user).as_json
            }, status: :created
          end

          def discuss
            current_briefing = briefing
            chat_session = ::App::JobDiscussionChatResolver.new(job: current_briefing.job, user: Current.user).resolve
            message = chat_session.messages.create!(
              role: "user",
              content: { "text" => discussion_message(current_briefing) },
              sender_user_id: Current.user.id
            )
            chat_session.pin_chat_provider!
            enqueue_chat_title(chat_session, message) if chat_session.messages.where(role: "user").count == 1
            enqueue_chat_turn(chat_session, message)

            render json: { redirect_to: "/chats/#{chat_session.id}" }
          end

          private

          def briefing
            @briefing ||= ::OperatorBriefing::Briefing
              .where(owner_user: Current.user, repository_id: Repository.accessible_repository_ids_for(Current.user))
              .find(params[:id])
          end

          def dive_params
            permitted = params.require(:dive).permit(:selected_text, :prompt)
            permitted[:evidence] = params.dig(:dive, :evidence) if params.dig(:dive, :evidence).is_a?(Array)
            permitted
          end

          def discuss_params
            params.fetch(:discussion, {}).permit(:message)
          end

          def discussion_message(current_briefing)
            [
              "Context: discuss the Operator Briefing for #{current_briefing.repository.slug}.",
              "Briefing Job: #{current_briefing.job.slug}.",
              "Window: #{current_briefing.window_start&.to_date} to #{current_briefing.window_end&.to_date}.",
              discuss_params[:message].to_s.strip.truncate(8_000)
            ].compact_blank.join("\n")
          end
        end
      end
    end
  end
end
