module Api
  module V1
    module App
      class MemoriesController < BaseController
        include Paginatable

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
          memory = find_memory_for_owner_or_admin
          return unless memory

          attrs = update_memory_params.to_h.symbolize_keys

          if attrs[:scope] == "global"
            attrs.merge!(scope_id: nil, published: false)
          elsif attrs[:scope_id].present?
            unless memory.user.repositories.exists?(id: attrs[:scope_id])
              return render_error("validation_failed", "Repository must belong to the memory owner.", status: :unprocessable_content)
            end
          end

          if memory.update(attrs)
            render json: memories_payload.merge(message: "Memory updated.")
          else
            render_validation_error(memory)
          end
        end

        def destroy
          memory = find_memory_for_owner_or_admin
          return unless memory

          memory.soft_delete_by!(Current.user)
          render json: memories_payload.merge(message: "Memory deleted.")
        end

        def publish
          memory = find_memory_for_owner_or_admin
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
          memory = find_memory_for_owner_or_admin
          return unless memory

          if memory.update(published: false)
            render json: memories_payload.merge(message: "Memory unpublished.")
          else
            render_validation_error(memory)
          end
        end

        def audit_events
          memory = find_memory_for_owner_or_admin
          return unless memory

          render json: {
            memory_id: memory.id,
            audit_events: memory.chat_memory_audit_events.includes(:actor_user).map { |event| audit_event_json(event) }
          }
        end

        private

        def memories_payload
          relation = filtered_memories
          total = relation.count
          page = page_param
          per_page = PER_PAGE
          total_pages = (total.to_f / per_page).ceil
          memories = relation
            .includes(:user, :repository, :deleted_by_user)
            .order(created_at: :desc, id: :desc)
            .offset((page - 1) * per_page)
            .limit(per_page)
          changed_memory_ids = changed_memory_ids_for(memories)

          {
            memories: memories.map { |memory| memory_json(memory, changed: changed_memory_ids.include?(memory.id)) },
            kinds: ChatMemory::KIND,
            scopes: ChatMemory::SCOPE,
            repositories: Current.user.repositories.active.order(:owner, :name).map { |repository| repository_json(repository) },
            filter: memory_filter.to_h,
            deleted: deleted_filter?,
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
          base = Current.user.admin? ? ChatMemory.all : ChatMemory.where(user_id: Current.user.id)
          deleted_filter? ? base.deleted : base.active
        end

        def deleted_filter?
          ActiveModel::Type::Boolean.new.cast(params[:deleted]) || false
        end

        def changed_memory_ids_for(memories)
          ChatMemoryAuditEvent.where(chat_memory_id: memories.map(&:id), event_type: %w[ updated deleted ])
                              .distinct.pluck(:chat_memory_id).to_set
        end

        def find_memory_for_owner_or_admin
          memory = ChatMemory.find(params[:id])
          return memory if Current.user.admin? || memory.user_id == Current.user.id

          render_error("forbidden", "You do not have permission to access this memory.", status: :forbidden)
          nil
        end

        def memory_json(memory, changed: false)
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
            changed: changed,
            deleted_at: memory.deleted_at&.iso8601,
            deleted_by: memory.deleted_by_user && {
              id: memory.deleted_by_user_id,
              name: memory.deleted_by_user.display_name
            },
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
              app_publish_path: "/api/v1/app/memories/#{memory.id}/publish",
              app_audit_events_path: "/api/v1/app/memories/#{memory.id}/audit_events"
            }
          }
        end

        def audit_event_json(event)
          {
            id: event.id,
            event_type: event.event_type,
            actor: audit_actor_json(event),
            previous: {
              content: event.previous_content,
              kind: event.previous_kind,
              confidence: event.previous_confidence
            },
            new: {
              content: event.new_content,
              kind: event.new_kind,
              confidence: event.new_confidence
            },
            created_at: event.created_at.iso8601
          }
        end

        def audit_actor_json(event)
          case event.actor_kind
          when "user"
            { kind: "user", id: event.actor_user_id, name: event.actor_user&.display_name }
          when "agent"
            { kind: "agent", run_id: event.actor_run_id }
          else
            { kind: "system" }
          end
        end

        def repository_json(repository)
          {
            id: repository.id,
            name: repository.slug
          }
        end

        def create_memory_params
          normalized_memory_params.permit(:content, :kind, :scope, :scope_id)
        end

        def update_memory_params
          normalized_memory_params.permit(:content, :kind, :scope, :scope_id)
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
