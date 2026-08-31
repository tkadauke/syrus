module Admin
  class StuckItemsCache
    CACHE_KEY = "admin:stuck_items:v1"
    CACHE_TTL = 10.minutes
    STALE_AFTER = 2.minutes

    Snapshot = Data.define(:items, :captured_at) do
      def stale?(now: Time.current)
        captured_at.nil? || captured_at < Admin::StuckItemsCache::STALE_AFTER.ago(now)
      end

      def as_json
        {
          items: items,
          captured_at: captured_at&.iso8601,
          stale: stale?
        }
      end
    end

    class << self
      def read
        raw = Rails.cache.read(CACHE_KEY)
        return empty_snapshot unless raw.is_a?(Hash)

        Snapshot.new(
          items: Array(raw["items"]),
          captured_at: parse_time(raw["captured_at"])
        )
      end

      def write(items:, captured_at: Time.current, force: false)
        snapshot = {
          "items" => Array(items),
          "captured_at" => captured_at&.iso8601
        }
        existing = read
        return existing if !force && !existing.stale? && existing.items == snapshot.fetch("items")

        Rails.cache.write(CACHE_KEY, snapshot, expires_in: CACHE_TTL)
        Snapshot.new(items: snapshot.fetch("items"), captured_at: parse_time(snapshot["captured_at"]))
      end

      def write_from_result(result:, now: Time.current)
        items = Admin::StuckItems.new(result: result, now: now).all.map do |item|
          Admin::StuckItemPayload.serialize(item: item)
        end
        write(items: items, captured_at: result.captured_at || now)
      end

      def empty_snapshot
        Snapshot.new(items: [], captured_at: nil)
      end

      private

      def parse_time(value)
        return value.to_time if value.respond_to?(:to_time)
        return nil if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
