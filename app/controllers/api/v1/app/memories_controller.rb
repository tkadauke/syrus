module Api
  module V1
    module App
      class MemoriesController < BaseController
        PER_PAGE = 20

        def index
          render json: memories_payload
        end

        def create
          memory = Current.user.chat_memories.new(create_memory_params)

          if memory.save
            render json: memories_payload.merge(message: "Memory created."), status: :created
          else
            render_validation_error(memory)
          end
        end

        def update
          memory = find_memory_for_write
          return unless memory

          if memory.update(update_memory_params)
            render json: memories_payload.merge(message: "Memory updated.")
          else
            render_validation_error(memory)
          end
        end

        def destroy
          memory = find_memory_for_write
          return unless memory

          memory.soft_delete_by!(Current.user)
          render json: memories_payload.merge(message: "Memory deleted.")
        end

        def publish
          memory = find_memory_for_write
          return unless memory

          if !memory.repository?
            render_error("validation_failed", "Only repository-scoped memories can be published.",
                         status: :unprocessable_content)
          elsif memory.update(published: true)
            render json: memories_payload.merge(message: "Memory published.")
          else
            render_validation_error(memory)
          end
        end

        def unpublish
          memory = find_memory_for_write
          return unless memory

          if memory.update(published: false)
            render json: memories_payload.merge(message: "Memory unpublished.")
          else
            render_validation_error(memory)
          end
        end

        private

        def memories_payload
          relation = filtered_memories
          total = relation.count
          page = page_param
          per_page = PER_PAGE
          total_pages = (total.to_f / per_page).ceil
          memories = relation
            .includes(:user, :repository)
            .order(created_at: :desc, id: :desc)
            .offset((page - 1) * per_page)
            .limit(per_page)

          {
            memories: memories.map { |memory| memory_json(memory) },
            kinds: ChatMemory::KIND,
            scopes: ChatMemory::SCOPE,
            repositories: Current.user.repositories.active.order(:owner, :name).map { |repository| repository_json(repository) },
            filter: memory_filter.to_h,
            controls: {
              filter_schema: ::Filters::Schema.for(subject: :memory, user: Current.user)
            },
            current_user: {
              id: Current.user.id,
              admin: Current.user.admin?
            },
            pagination: {
              page: page,
              per_page: per_page,
              total: total,
              total_pages: total_pages
            }
          }
        end

        def filtered_memories
          memory_filter.apply(visible_memories)
        end

        def memory_filter
          @memory_filter ||= ::Memories::Filter.from_params(params, user: Current.user)
        end

        def visible_memories
          return ChatMemory.active if Current.user.admin?

          repository_ids = Current.user.repositories.active.select(:id)
          ChatMemory.active.where(user_id: Current.user.id)
            .or(ChatMemory.active.where(scope: "repository", scope_id: repository_ids, published: true))
        end

        def find_memory_for_write
          memory = ChatMemory.find(params[:id])
          return memory if Current.user.admin? || memory.user_id == Current.user.id

          render_error("forbidden", "You do not have permission to modify this memory.", status: :forbidden)
          nil
        end

        def memory_json(memory)
          can_manage = Current.user.admin? || memory.user_id == Current.user.id
          can_publish = can_manage && memory.repository?

          {
            id: memory.id,
            kind: memory.kind,
            scope: memory.scope,
            scope_id: memory.scope_id,
            repository_name: memory.repository&.slug,
            content: memory.content,
            published: memory.published?,
            created_at: memory.created_at.iso8601,
            updated_at: memory.updated_at.iso8601,
            owner: {
              id: memory.user_id,
              name: memory.user.display_name
            },
            permissions: {
              can_manage: can_manage,
              can_publish: can_publish
            },
            paths: {
              app_memory_path: "/api/v1/app/memories/#{memory.id}",
              app_publish_path: "/api/v1/app/memories/#{memory.id}/publish"
            }
          }
        end

        def repository_json(repository)
          {
            id: repository.id,
            name: repository.slug
          }
        end

        def page_param
          page = params[:page].to_i
          page.positive? ? page : 1
        end

        def create_memory_params
          normalized_memory_params.permit(:content, :kind, :scope, :scope_id)
        end

        def update_memory_params
          normalized_memory_params.permit(:content, :kind)
        end

        def normalized_memory_params
          source = params[:memory].presence || params
          permitted = source.permit(:content, :kind, :scope, :scope_id, :repository_id)
          if permitted[:scope] == "repository" && permitted[:scope_id].blank? && permitted[:repository_id].present?
            permitted[:scope_id] = permitted[:repository_id]
          end
          permitted.except(:repository_id)
        end

        def render_validation_error(memory)
          render_error("validation_failed", memory.errors.full_messages.to_sentence,
                       status: :unprocessable_content)
        end
      end
    end
  end
end
