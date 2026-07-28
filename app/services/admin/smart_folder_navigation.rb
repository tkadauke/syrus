module Admin
  class SmartFolderNavigation
    include Rails.application.routes.url_helpers

    def self.active_folder(subject:, user:, params:)
      id = Integer(params[:smart_folder_id], exception: false)
      return nil unless id

      SmartFolder
        .for_subject(subject)
        .where("user_id IS NULL OR user_id = ?", user.id)
        .find_by(id: id)
    end

    def initialize(subject:, user:, active_folder:, base_scope:, filter_class:, path_context: {})
      @subject = subject.to_s
      @user = user
      @active_folder = active_folder
      @base_scope = base_scope
      @filter_class = filter_class
      @path_context = path_context
    end

    def folders
      candidate_folders.filter_map do |folder|
        count = smart_folder_count(folder)
        next unless smart_folder_visible?(folder, count)

        {
          id: folder.id,
          name: folder.name,
          i18n_key: builtin_i18n_key(folder),
          position: folder.position,
          kind: folder.kind,
          subject_type: folder.subject_type,
          visibility: folder.visibility.to_s,
          count: count,
          active: active_folder&.id == folder.id,
          filter: folder.filter,
          path: folder_path(folder)
        }
      end
    end

    private

    attr_reader :subject, :user, :active_folder, :base_scope, :filter_class, :path_context

    def builtin_i18n_key(folder)
      return nil unless folder.builtin?

      definitions = SmartFolder::BUILTINS_BY_SUBJECT.fetch(folder.subject_type, [])
      definitions.find { |d| d[:name] == folder.name }&.fetch(:key, nil)&.to_s
    end

    def candidate_folders
      @candidate_folders ||= SmartFolder
        .for_subject(subject)
        .where("user_id IS NULL OR user_id = ?", user.id)
        .order(Arel.sql("CASE WHEN user_id IS NULL THEN 0 ELSE 1 END"), :position, :id)
    end

    def smart_folder_visible?(folder, count)
      return true unless folder.builtin?
      return true if active_folder&.id == folder.id
      return count.positive? if folder.visibility == :when_present

      true
    end

    def smart_folder_count(folder)
      filter_class.from_tree(folder.filter, user: user).apply(base_scope).count
    end

    def folder_path(folder)
      case subject
      when "admin_user"
        admin_users_path(smart_folder_id: folder.id)
      when "admin_queue"
        admin_queue_path(path_context.fetch(:tab), smart_folder_id: folder.id)
      when "spawned_process"
        admin_processes_path(smart_folder_id: folder.id)
      else
        smart_folders_path(subject_type: subject)
      end
    end
  end
end
