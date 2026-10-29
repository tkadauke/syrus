module Coworkers
  class MessageRateLimiter
    LIMIT = 10
    WINDOW = 10.minutes
    Result = Data.define(:allowed, :retry_after_seconds) do
      def allowed? = allowed
    end

    def self.reserve(sender:, receiver:, cache: Rails.cache, now: Time.current)
      new(sender: sender, receiver: receiver, cache: cache, now: now).reserve
    end

    def initialize(sender:, receiver:, cache:, now:)
      @sender = sender
      @receiver = receiver
      @cache = cache
      @now = now
    end

    def reserve
      count = reserve_slot
      Result.new(allowed: count <= LIMIT, retry_after_seconds: retry_after_seconds)
    end

    private

    attr_reader :sender, :receiver, :cache, :now

    def reserve_slot
      return 1 if cache.write(cache_key, 1, expires_in: WINDOW, unless_exist: true)

      cache.increment(cache_key, 1, expires_in: WINDOW) || LIMIT + 1
    end

    def cache_key
      coworker_ids = [ sender.id, receiver.id ].sort.join(":")
      "coworker-message-rate:v1:owner:#{sender.owner_user_id}:pair:#{coworker_ids}:window:#{window_number}"
    end

    def window_number = now.to_i / WINDOW.to_i
    def retry_after_seconds = WINDOW.to_i - (now.to_i % WINDOW.to_i)
  end
end
