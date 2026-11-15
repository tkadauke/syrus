module App
  class DashboardChromeCache
    GLOBAL_REVISION_KEY = "dashboard_chrome:revision:global"

    class << self
      def revision_for(user)
        [ Rails.cache.read(GLOBAL_REVISION_KEY) || "initial", Rails.cache.read(user_revision_key(user.id)) || "initial" ]
      end

      def invalidate_all!
        write_revision(GLOBAL_REVISION_KEY)
      end

      def invalidate_user!(user_or_id)
        user_id = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
        write_revision(user_revision_key(user_id)) if user_id
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
    end
  end
end
