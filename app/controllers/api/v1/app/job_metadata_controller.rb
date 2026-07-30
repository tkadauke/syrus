module Api
  module V1
    module App
      class JobMetadataController < BaseController
        def add_tag
          job = find_job
          tag = find_or_create_tag_from_params
          return unless tag

          job.job_tags.find_or_create_by!(tag: tag)
          render_metadata(job.reload, message: "Tag added.", changed: [ "tags" ])
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def remove_tag
          job = find_job
          tag = Current.user.tags.find_by(id: params[:tag_id])
          unless tag
            render_error("not_found", "Tag not found.", status: :not_found)
            return
          end

          job.job_tags.where(tag: tag).destroy_all
          render_metadata(job.reload, message: "Tag removed.", changed: [ "tags" ])
        end

        def add_dependency
          job = find_job
          target = dependency_target_for(job)
          unless target
            render_error("not_found", "Dependency Job not found.", status: :not_found)
            return
          end

          dependency = job.dependencies.find_or_initialize_by(depends_on_job: target)
          dependency.source ||= "manual"
          dependency.created_by_user ||= Current.user

          if dependency.save
            render_metadata(job.reload, message: "Dependency added.", changed: [ "dependencies" ])
          else
            render_error("validation_failed", dependency.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def remove_dependency
          job = find_job
          dependency = job.dependencies.find_by(id: params[:dependency_id])
          unless dependency
            render_error("not_found", "Dependency not found.", status: :not_found)
            return
          end

          unless dependency.manual?
            render_error("validation_failed", "Parsed dependencies are kept for audit.", status: :unprocessable_content)
            return
          end

          dependency.destroy!
          job.start_pending_workflows_if_dependencies_satisfied!
          render_metadata(job.reload, message: "Dependency removed.", changed: [ "dependencies" ])
        end

        def add_epic_dependency
          job = find_job
          epic_id = params[:depends_on_epic_id].to_i
          epic = Current.user.epics.find_by(id: epic_id)
          unless epic
            render_error("not_found", "Epic not found.", status: :not_found)
            return
          end

          dependency = job.dependencies.find_or_initialize_by(depends_on_epic: epic)
          dependency.source ||= "manual"
          dependency.created_by_user ||= Current.user

          if dependency.save
            render_metadata(job.reload, message: "Epic dependency added.", changed: [ "dependencies" ])
          else
            render_error("validation_failed", dependency.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def remove_epic_dependency
          job = find_job
          dependency = job.dependencies.find_by(depends_on_epic_id: params[:depends_on_epic_id])
          unless dependency
            render_error("not_found", "Epic dependency not found.", status: :not_found)
            return
          end

          unless dependency.manual?
            render_error("validation_failed", "Parsed dependencies are kept for audit.", status: :unprocessable_content)
            return
          end

          dependency.destroy!
          job.start_pending_workflows_if_dependencies_satisfied!
          render_metadata(job.reload, message: "Epic dependency removed.", changed: [ "dependencies" ])
        end

        def override_dependencies
          job = find_job
          unless Current.user.admin?
            render_error("forbidden", "Only admins can override dependencies.", status: :forbidden)
            return
          end

          job.force_run_dependencies!(user: Current.user)
          render_metadata(job.reload, message: "Dependency gate overridden.", changed: [ "dependencies" ])
        end

        def stack_base
          job = find_job
          value = params[:stack_base].to_s
          unless Job::STACK_BASES.include?(value)
            render_error("validation_failed", "Unknown stack base.", status: :unprocessable_content)
            return
          end

          job.update!(stack_base: value)
          job.start_pending_workflows_if_dependencies_satisfied!
          render_metadata(job.reload, message: "Stack base updated.", changed: [ "stack_base" ])
        end

        def mark_valid
          job = find_job
          unless job.validity_duplicate? || job.validity_already_implemented?
            render_error("validation_failed", "Job is already marked valid.", status: :unprocessable_content)
            return
          end

          job.mark_valid_and_queue!
          render_metadata(job.reload, message: "Job marked valid and re-queued.", changed: [ "validity", "state" ])
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs.includes(:repository, :tags, dependencies: [ :created_by_user, :depends_on_epic, depends_on_job: :repository ]), params[:job_id])
        end

        def find_or_create_tag_from_params
          name = params[:tag_name].to_s.strip
          if name.blank?
            render_error("validation_failed", "Tag name can't be blank.", status: :unprocessable_content)
            return nil
          end

          Current.user.tags.find_or_create_by!(name: name) { |tag| tag.color = "gray" }
        end

        def dependency_target_for(job)
          type, first, second = params[:dependency_target].to_s.split(":", 3)

          case type
          when "job"
            Current.user.jobs.where.not(id: job.id).find_by(id: first)
          when "issue"
            repository = Current.user.repositories.find_by(id: first)
            repository&.jobs&.where(kind: "issue", issue_number: second)&.where.not(id: job.id)&.order(created_at: :desc, id: :desc)&.first
          end
        end

        def render_metadata(job, message:, changed:)
          AppEvents.broadcast(
            user: Current.user,
            type: "updated",
            resource: "job",
            id: job.id,
            changed: changed
          )

          render json: metadata_payload(job, message: message)
        end

        def metadata_payload(job, message:)
          {
            message: message,
            job: {
              id: job.id,
              state: job.state,
              stack_base: job.stack_base,
              validity: job.validity,
              dependencies_overridden_at: job.dependencies_overridden_at&.iso8601,
              dependencies_overridden_by_user_id: job.dependencies_overridden_by_user_id
            },
            tags: job.tags.ordered.map { |tag| tag_json(tag) },
            dependencies: job.dependencies.includes(:created_by_user, depends_on_job: :repository).map { |dependency| dependency_json(dependency) },
            paths: {
              job_path: job_path(job)
            }
          }
        end

        def tag_json(tag)
          {
            id: tag.id,
            name: tag.name,
            color: tag.color
          }
        end

        def dependency_json(dependency)
          {
            id: dependency.id,
            source: dependency.source,
            manual: dependency.manual?,
            depends_on_job_id: dependency.depends_on_job_id,
            depends_on_epic_id: dependency.depends_on_epic_id,
            label: if dependency.depends_on_job
                     dependency_label(dependency.depends_on_job)
                   elsif dependency.depends_on_epic
                     dependency_epic_label(dependency.depends_on_epic)
                   else
                     dependency.unresolved_slug
                   end,
            created_by_user_id: dependency.created_by_user_id
          }
        end

        def dependency_label(job)
          if job.issue? && job.issue_number.present?
            title = job.issue_title.to_s.strip
            title = " — #{title}" if title.present?
            "#{job.repository.slug} ##{job.issue_number}#{title} (#{job.slug})"
          else
            title = job.issue_title.to_s.strip.presence || job.kind.titleize
            "#{job.repository.slug} #{job.slug} — #{title}"
          end
        end

        def dependency_epic_label(epic)
          "#{epic.slug} — #{epic.title}"
        end
      end
    end
  end
end
