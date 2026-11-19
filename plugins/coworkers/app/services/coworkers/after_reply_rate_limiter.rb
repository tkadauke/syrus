module Coworkers
  class AfterReplyRateLimiter
    LIMIT = Coworkers::MessageRateLimiter::LIMIT
    WINDOW = Coworkers::MessageRateLimiter::WINDOW
    Result = Data.define(:allowed, :retry_after_seconds) do
      def allowed? = allowed
    end

    def self.reserve(chat:, coworker:, cache: Rails.cache, now: Time.current)
      new(chat:, coworker:, cache:, now:).reserve
    end

    def initialize(chat:, coworker:, cache:, now:)
      @chat = chat
      @coworker = coworker
      @cache = cache
      @now = now
    end

    def reserve
      count = if cache.write(cache_key, 1, expires_in: WINDOW, unless_exist: true)
        1
      else
        cache.increment(cache_key, 1, expires_in: WINDOW) || LIMIT + 1
      end
      Result.new(allowed: count <= LIMIT, retry_after_seconds: WINDOW.to_i - (now.to_i % WINDOW.to_i))
    end

    private

    attr_reader :chat, :coworker, :cache, :now

    def cache_key
      "coworker-after-reply:v1:chat:#{chat.id}:coworker:#{coworker.id}:window:#{now.to_i / WINDOW.to_i}"
    end
  end
end
