class Coworkers::OperationLock
  Busy = Class.new(StandardError)
  WAIT_SECONDS = 0

  class << self
    def with(coworker_or_id, wait: WAIT_SECONDS, &block)
      key = "coworker:#{coworker_or_id.respond_to?(:id) ? coworker_or_id.id : coworker_or_id}"
      mysql? ? with_mysql_lock(key, wait:, &block) : local_lock(key).synchronize(&block)
    end

    private

    def mysql?
      ApplicationRecord.connection.adapter_name.match?(/mysql/i)
    end

    def with_mysql_lock(key, wait:)
      connection = ApplicationRecord.connection
      quoted = connection.quote(key)
      acquired = connection.select_value("SELECT GET_LOCK(#{quoted}, #{Integer(wait)})").to_i == 1
      raise Busy, "#{key} is busy" unless acquired

      yield
    ensure
      connection&.select_value("SELECT RELEASE_LOCK(#{quoted})") if acquired
    end

    def local_lock(key)
      mutex_guard.synchronize { mutexes[key] ||= Mutex.new }
    end

    def mutex_guard = (@mutex_guard ||= Mutex.new)
    def mutexes = (@mutexes ||= {})
  end
end
