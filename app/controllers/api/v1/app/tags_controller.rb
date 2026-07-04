module Api
  module V1
    module App
      class TagsController < BaseController
        def index
          render json: tags_payload
        end

        def create
          tag = Current.user.tags.new(tag_params)

          if tag.save
            render json: tags_payload.merge(message: I18n.t("api.tags.created")), status: :created
          else
            render_error("validation_failed", tag.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        def update
          tag = Current.user.tags.find(params[:id])

          if tag.update(tag_params)
            render json: tags_payload.merge(message: I18n.t("api.tags.updated"))
          else
            render_error("validation_failed", tag.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        def destroy
          tag = Current.user.tags.find(params[:id])
          tag.destroy!

          render json: tags_payload.merge(message: I18n.t("api.tags.deleted"))
        end

        private

        def tags_payload
          tags = Current.user.tags.ordered.includes(:jobs)

          {
            palette: Tag::PALETTE.map do |key, colors|
              {
                key: key,
                label: key.titleize,
                bg: colors[:bg],
                text: colors[:text]
              }
            end,
            tags: tags.map { |tag| tag_json(tag) }
          }
        end

        def tag_json(tag)
          {
            id: tag.id,
            name: tag.name,
            color: tag.color,
            jobs_count: tag.jobs.size
          }
        end

        def tag_params
          params.expect(tag: [ :name, :color ])
        end
      end
    end
  end
end
