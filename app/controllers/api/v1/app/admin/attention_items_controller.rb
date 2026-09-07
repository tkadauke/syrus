module Api
  module V1
    module App
      module Admin
        class AttentionItemsController < BaseController
          def index
            render json: ::Admin::AttentionItemsPayload.new(params: params).index_json
          rescue ArgumentError, TypeError => e
            render_error("bad_request", e.message, status: :bad_request)
          end

          def decide
            item = AttentionItem.find(params[:id])
            unless AttentionItem::RESOLUTIONS.include?(params[:resolution].to_s)
              render_error("bad_request", "resolution must be one of #{AttentionItem::RESOLUTIONS.join(', ')}", status: :bad_request)
              return
            end
            unless item.open?
              render_error("not_open", "This item was already decided.", status: :conflict)
              return
            end

            item.decide!(resolution: params[:resolution], user: Current.user, reason: params[:reason].presence)
            render json: ::Admin::AttentionItemsPayload.render_item(item.reload)
          rescue ActiveRecord::RecordNotFound
            render_error("not_found", "Attention item not found.", status: :not_found)
          end

          def act
            item = AttentionItem.find(params[:id])
            result = AttentionItems::ActionExecutor.call(
              attention_item: item,
              action_key: params[:action_key],
              user: Current.user,
              reason: params[:reason].presence
            )

            unless result.success?
              render_error("action_failed", result.error, status: :unprocessable_entity)
              return
            end

            render json: ::Admin::AttentionItemsPayload.render_item(item.reload)
          rescue ActiveRecord::RecordNotFound
            render_error("not_found", "Attention item not found.", status: :not_found)
          end
        end
      end
    end
  end
end
