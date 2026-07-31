module Api
  module V1
    module Admin
      # Admin API for Epics. Parallel shape to JobsController:
      #   GET /api/v1/admin/epics       → compact list (filterable)
      #   GET /api/v1/admin/epics/:id   → full detail (child jobs + deps)
      class EpicsController < BaseController
        # Compact list. Filter via:
        #   ?state=backlog|ready|in_progress|done|archived
        #   ?repo=owner/name
        #   ?user=substring                — match User#email_address
        #   ?owner=mine|other_owned|unclaimed
        #   ?has_unfinished_children=true  — Epics with at least one
        #                                    child Job that hasn't closed
        #                                    successfully. "What's still
        #                                    blocking the Epic from
        #                                    completing?"
        # No filters → most-recently updated 50.
        def index
          scope = Epic.includes(:owner, :repository, :owner_user).order(updated_at: :desc)
          scope = scope.where(state: params[:state]) if params[:state].present?
          if params[:repo].present?
            owner, name = params[:repo].split("/", 2)
            scope = scope.joins(:repository).where(repositories: { owner: owner, name: name })
          end
          if params[:user].present?
            scope = scope.joins(:user).where("users.email_address LIKE ?", "%#{params[:user]}%")
          end
          scope = apply_owner_filter(scope)
          if truthy?(params[:has_unfinished_children])
            scope = scope.where(id: unfinished_child_epic_ids)
          end
          epics = scope.limit(50)
          render json: {
            count: epics.size,
            epics: epics.map { |e| serialize_compact(e) }
          }
        end

        def show
          epic = Epic.includes(:repository, :user, :owner_user, dependencies: :depends_on_epic,
                                                    dependent_links: :epic,
                                                    jobs: [ :repository, :owner_user ])
                     .find(params[:id])
          render json: serialize(epic)
        end

        def create
          attrs = epic_params
          repository = find_active_repository(attrs)
          return render_error("validation_failed", "Repository not found or not active.", status: :unprocessable_content) unless repository

          owner_user = find_owner_user(attrs[:owner_user_id])
          return render_error("validation_failed", "Owner user not found.", status: :unprocessable_content) if attrs[:owner_user_id].present? && !owner_user

          epic = repository.user.epics.new(
            repository: repository,
            title: attrs[:title],
            description: attrs[:description],
            github_issue_url: attrs[:github_issue_url],
            owner_user: owner_user
          )
          epic.auto_approve_mode = attrs[:auto_approve_mode] if attrs[:auto_approve_mode].present?
          epic.reconciliation_mode = attrs[:reconciliation_mode] if attrs.key?(:reconciliation_mode)
          epic.epic_dependency_policy = attrs[:epic_dependency_policy] if attrs.key?(:epic_dependency_policy)

          if epic.save
            render json: {
              message: "Epic created.",
              epic: serialize(epic.reload)
            }, status: :created
          else
            render_error("validation_failed", epic.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        private

        def epic_params
          source = params[:epic].present? ? params.require(:epic) : params
          source.permit(:repository_id, :repository, :repo, :title, :description, :github_issue_url, :owner_user_id, :auto_approve_mode, :reconciliation_mode, :epic_dependency_policy)
        end

        def find_active_repository(attrs)
          scope = Repository.active.includes(:user)
          if attrs[:repository_id].present?
            scope.find_by(id: attrs[:repository_id])
          else
            slug = attrs[:repository].presence || attrs[:repo].presence
            return if slug.blank?

            owner, name = slug.to_s.split("/", 2)
            return if owner.blank? || name.blank?

            scope.find_by(owner: owner, name: name)
          end
        end

        def find_owner_user(owner_user_id)
          return if owner_user_id.blank?

          User.find_by(id: owner_user_id)
        end

        def truthy?(value)
          %w[ true 1 yes ].include?(value.to_s.downcase)
        end

        def apply_owner_filter(scope)
          case params[:owner].to_s
          when "mine"
            scope.owned_by(current_api_user)
          when "other_owned"
            scope.other_owned_by(current_api_user)
          when "unclaimed"
            scope.unclaimed
          else
            scope
          end
        end

        # Epic IDs that have at least one child Job not closed with a
        # successful closure_reason. Mirrors Epic#complete?, inverted.
        def unfinished_child_epic_ids
          successful_reasons = Epic::SUCCESSFUL_JOB_CLOSURE_REASONS
          Job.where("(state != 'closed' OR closure_reason IS NULL OR closure_reason NOT IN (?))", successful_reasons)
             .where.not(epic_id: nil)
             .distinct
             .pluck(:epic_id)
        end

        def serialize_compact(epic)
          {
            id:                 epic.id,
            number:             epic.number,
            display_number:     epic.slug,
            state:              epic.state,
            title:              epic.title,
            owner_email:        epic.owner&.email_address,
            claimed_at:         epic.claimed_at,
            auto_approve_mode:      epic.auto_approve_mode,
            reconciliation_mode:    epic.reconciliation_mode,
            epic_dependency_policy: epic.epic_dependency_policy,
            resolved_epic_dependency_policy: epic.resolved_epic_dependency_policy,
            owner_user_id:          epic.owner_user_id,
            owner_status:           owner_status(epic),
            owner_user:             owner_user_json(epic.owner_user),
            repository:             epic.repository.slug,
            github_issue_url:   epic.github_issue_url,
            done_at:            epic.done_at,
            created_at:         epic.created_at,
            updated_at:         epic.updated_at
          }
        end

        def serialize(epic)
          {
            id:                 epic.id,
            number:             epic.number,
            display_number:     epic.slug,
            state:              epic.state,
            title:              epic.title,
            description:        epic.description,
            owner:              serialize_owner(epic.owner),
            claimed_at:         epic.claimed_at,
            auto_approve_mode:   epic.auto_approve_mode,
            reconciliation_mode: epic.reconciliation_mode,
            epic_dependency_policy: epic.epic_dependency_policy,
            resolved_epic_dependency_policy: epic.resolved_epic_dependency_policy,
            owner_user_id:       epic.owner_user_id,
            owner_status:        owner_status(epic),
            owner_user:          owner_user_json(epic.owner_user),
            github_issue_url:    epic.github_issue_url,
            done_at:            epic.done_at,
            created_at:         epic.created_at,
            updated_at:         epic.updated_at,
            repository: {
              id:             epic.repository.id,
              slug:           epic.repository.slug,
              default_branch: epic.repository.default_branch
            },
            user_email: epic.user.email_address,
            ready_to_start:      epic.ready_to_start?,
            complete:            epic.complete?,
            depends_on_epic_ids: epic.dependencies.map(&:depends_on_epic_id).compact,
            dependent_epic_ids:  epic.dependent_links.map(&:epic_id),
            pending_epic_dependency_refs: epic.pending_epic_dependency_refs,
            jobs: epic.jobs.map { |j| serialize_child_job(j) }
          }
        rescue => e
          { error_serializing: "#{e.class}: #{e.message}" }
        end

        def serialize_owner(owner)
          return nil unless owner

          {
            id: owner.id,
            email_address: owner.email_address
          }
        end

        def serialize_child_job(job)
          {
            id:             job.id,
            state:          job.state,
            kind:           job.kind,
            validity:       job.validity,
            closure_reason: job.closure_reason,
            owner_user_id:  job.owner_user_id,
            owner_user:     owner_user_json(job.owner_user),
            issue_number:   job.issue_number,
            pr_number:      job.pr_number,
            repository:     job.repository.slug,
            updated_at:     job.updated_at
          }
        rescue => e
          { id: job.id, error_serializing: "#{e.class}: #{e.message}" }
        end

        def owner_status(epic)
          return "unclaimed" if epic.owner_user_id.blank?
          return "mine" if epic.owner_user_id == current_api_user.id

          "other_owned"
        end

        def owner_user_json(owner_user)
          return nil unless owner_user

          {
            id: owner_user.id,
            email_address: owner_user.email_address
          }
        end
      end
    end
  end
end
