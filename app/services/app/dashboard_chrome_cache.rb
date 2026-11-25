module App
  class DashboardChromeCache
    GLOBAL_REVISION_KEY = "dashboard_chrome:revision:global"

    class << self
      def revision_for(user)
        [ Rails.cache.read(GLOBAL_REVISION_KEY) || "initial", Rails.cache.read(user_revision_key(user.id)) || "initial" ]
      end

      def count_revision_for(user:, repository_ids:, subject:)
        repository_keys = Array(repository_ids).map { |repository_id| count_revision_key(repository_id, subject) }
        visibility_keys = [ GLOBAL_REVISION_KEY, user_revision_key(user.id) ]
        revisions = Rails.cache.read_multi(*visibility_keys, *repository_keys)

        [
          visibility_keys.map { |key| revisions.fetch(key, "initial") },
          repository_keys.map { |key| revisions.fetch(key, "initial") }
        ]
      end

      def invalidate_all!
        write_revision(GLOBAL_REVISION_KEY)
      end

      def invalidate_user!(user_or_id)
        user_id = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
        write_revision(user_revision_key(user_id)) if user_id
      end

      def invalidate_counts!(repository_or_id, subjects:)
        repository_id = repository_or_id.respond_to?(:id) ? repository_or_id.id : repository_or_id
        return unless repository_id

        Array(subjects).each do |subject|
          write_revision(count_revision_key(repository_id, subject))
        end
      end

      private

      def write_revision(key)
        Rails.cache.write(key, SecureRandom.uuid)
      rescue StandardError => error
        Rails.logger.warn("Dashboard chrome cache invalidation skipped: #{error.class}: #{error.message}")
        false
      end

      def user_revision_key(user_id)
        "dashboard_chrome:revision:user:#{user_id}"
      end

      def count_revision_key(repository_id, subject)
        "dashboard_chrome:count_revision:repository:#{repository_id}:#{subject}"
      end
    end
  end
end
