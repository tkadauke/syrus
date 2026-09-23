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

    def initialize(subject:, user:, active_folder:, base_scope:, filter_class:, path_context: {}, count_provider: nil)
      @subject = subject.to_s
      @user = user
      @active_folder = active_folder
      @base_scope = base_scope
      @filter_class = filter_class
      @path_context = path_context
      @count_provider = count_provider
    end

    def folders
      candidate_folders.filter_map do |folder|
        count_info = smart_folder_count(folder)
        count = count_info.fetch(:count)
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
          count_capped: count_info.fetch(:count_capped),
          active: active_folder&.id == folder.id,
          filter: folder.filter,
          path: folder_path(folder)
        }
      end
    end

    private

    attr_reader :subject, :user, :active_folder, :base_scope, :filter_class, :path_context, :count_provider

    def builtin_i18n_key(folder)
      return nil unless folder.builtin?

      definitions = SmartFolder.builtins_by_subject.fetch(folder.subject_type, [])
      definitions.find { |d| d[:name] == folder.name }&.fetch(:key, nil)&.to_s
    end

    def candidate_folders
      @candidate_folders ||= deduplicate_builtin_folders(SmartFolder
        .for_subject(subject)
        .where("user_id IS NULL OR user_id = ?", user.id)
        .order(Arel.sql("CASE WHEN user_id IS NULL THEN 0 ELSE 1 END"), :position, :id)
        .to_a)
    end

    def deduplicate_builtin_folders(folders)
      folders
        .group_by { |folder| builtin_deduplication_key(folder) }
        .values
        .flat_map { |group| group.size == 1 ? group : [ canonical_builtin_folder(group) ] }
        .sort_by { |folder| [ folder.user_id.nil? ? 0 : 1, folder.position, folder.id ] }
    end

    def builtin_deduplication_key(folder)
      return [ folder.id ] unless folder.builtin? && folder.user_id.nil?

      [ folder.kind, folder.subject_type, folder.name ]
    end

    def canonical_builtin_folder(folders)
      folders.find { |folder| active_folder&.id == folder.id } || folders.max_by(&:id)
    end

    def smart_folder_visible?(folder, count)
      return true unless folder.builtin?
      return true if active_folder&.id == folder.id
      return count.positive? if folder.visibility == :when_present

      true
    end

    def smart_folder_count(folder)
      provided = count_provider&.call(folder)
      return normalize_provided_count(provided) unless provided.nil?

      filter = filter_class.from_tree(folder.filter, user: user)
      count = filter.capped_count(filter.apply(base_scope))
      { count: count, count_capped: count >= SmartFolder::COUNT_CAP }
    end

    # A count_provider may return a bare count (assumed uncapped, e.g. a
    # hand-rolled exact SQL count) or a { count:, count_capped: } Hash when
    # it applies its own capping (e.g. AgentActivity::SessionsQuery delegating
    # to the shared Filters::BaseFilter.capped_count) -- so a folder capped
    # through a custom provider still renders "999+" instead of a bare,
    # suspiciously-round number.
    def normalize_provided_count(provided)
      return provided if provided.is_a?(Hash)

      { count: provided, count_capped: false }
    end

    def folder_path(folder)
      case subject
      when "admin_user"
        admin_users_path(smart_folder_id: folder.id)
      when "admin_queue"
        admin_queue_path(path_context.fetch(:tab), smart_folder_id: folder.id)
      when "spawned_process"
        admin_processes_path(smart_folder_id: folder.id)
      when "repository"
        repositories_path(smart_folder_id: folder.id)
      else
        SmartFolder.path_for_subject(subject, smart_folder_id: folder.id) || smart_folders_path(subject_type: subject)
      end
    end
  end
end
