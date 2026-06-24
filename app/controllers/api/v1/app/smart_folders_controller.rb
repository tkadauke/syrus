module Api
  module V1
    module App
      class SmartFoldersController < BaseController
        def index
          render json: smart_folders_payload
        end

        def create
          subject_type = smart_folder_subject
          tree = parsed_filter_tree
          filter_ast = ::Filters::Ast.parse(tree || legacy_filter_tree(subject_type))
          filter = ::Filters::Ast.serialize(filter_ast)

          if empty_filter?(filter_ast)
            render_error("validation_failed", "Choose at least one filter before saving a smart folder.", status: :unprocessable_content)
            return
          end

          folder = Current.user.smart_folders.new(
            name: smart_folder_params[:name],
            kind: "user_defined",
            subject_type: subject_type,
            filter: filter,
            position: next_position(subject_type)
          )

          if folder.save
            render json: smart_folders_payload(subject_type: subject_type).merge(
              message: "Smart folder saved.",
              redirect_to: dashboard_path_for(subject_type, smart_folder_id: folder.id),
              smart_folder: smart_folder_json(folder)
            ), status: :created
          else
            render_error("validation_failed", folder.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        rescue ArgumentError => e
          render_error("validation_failed", "Couldn't save filter: #{e.message}", status: :unprocessable_content)
        end

        def update
          smart_folder = Current.user.smart_folders.find(params[:id])
          attributes = smart_folder_params.to_h

          if params.key?(:filter)
            filter_ast = ::Filters::Ast.parse(parsed_filter_tree)
            if empty_filter?(filter_ast)
              render_error("validation_failed", "Choose at least one filter before saving a smart folder.", status: :unprocessable_content)
              return
            end

            attributes[:filter] = ::Filters::Ast.serialize(filter_ast)
          end

          if smart_folder.update(attributes)
            render json: smart_folders_payload(subject_type: smart_folder.subject_type).merge(message: "Smart folder updated.")
          else
            render_error("validation_failed", smart_folder.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        rescue ArgumentError => e
          render_error("validation_failed", "Couldn't save filter: #{e.message}", status: :unprocessable_content)
        end

        def destroy
          smart_folder = Current.user.smart_folders.find(params[:id])
          subject_type = smart_folder.subject_type
          smart_folder.destroy!

          render json: smart_folders_payload(subject_type: subject_type).merge(message: "Smart folder deleted.")
        end

        private

        def smart_folders_payload(subject_type: smart_folder_subject)
          folders = SmartFolder.for_user(Current.user, subject: subject_type)

          {
            subject_type: subject_type,
            subject_label: subject_type.humanize,
            dashboard_path: dashboard_path_for(subject_type),
            smart_folders: folders.map { |folder| smart_folder_json(folder) }
          }
        end

        def smart_folder_json(folder)
          {
            id: folder.id,
            name: folder.name,
            position: folder.position,
            filter: folder.filter
          }
        end

        def smart_folder_params
          params.expect(smart_folder: [ :name, :position ])
        end

        def smart_folder_subject
          params[:subject_type].to_s.presence_in(SmartFolder::SUBJECT_TYPES) || "job"
        end

        def dashboard_path_for(subject_type, **query)
          case subject_type
          when "admin_user"
            admin_users_path(query)
          when "admin_queue"
            admin_queue_root_path(query)
          when "workflow"
            dashboard_workflows_path(query)
          when "epic"
            dashboard_epics_path(query)
          when "spawned_process"
            admin_processes_path(query)
          else
            dashboard_jobs_path(query)
          end
        end

        def legacy_filter_tree(subject_type)
          case subject_type
          when "admin_user"
            Admin::Users::Filter.from_params(params, user: Current.user).to_h
          when "admin_queue"
            Admin::Queue::Filter.from_params(params, tab: :active).to_h
          when "workflow"
            Workflows::Filter.from_params(params).to_h
          when "epic"
            Epics::Filter.from_params(params).to_h
          when "spawned_process"
            Admin::SpawnedProcesses::Filter.from_params(params).to_h
          else
            Jobs::Filter.from_params(params).to_h
          end
        end

        def parsed_filter_tree
          raw = params[:filter]
          return nil if raw.blank?

          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end

        def next_position(subject_type)
          (Current.user.smart_folders.where(subject_type: subject_type).maximum(:position) || -1) + 1
        end

        def empty_filter?(filter_ast)
          filter_ast.is_a?(::Filters::Ast::AndNode) && filter_ast.children.empty?
        end
      end
    end
  end
end
