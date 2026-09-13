class StorageConnectivity
  RETRY_AFTER_SECONDS = 30
  PROBE_KEY = "syrus/storage-health/probe".freeze

  TRANSIENT_ERROR_CLASSES = [
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::ETIMEDOUT,
    Net::OpenTimeout,
    Net::ReadTimeout,
    SocketError,
    Timeout::Error,
    IOError,
    EOFError
  ].freeze

  TRANSIENT_ERROR_NAME_PATTERN = /\A(?:Seahorse::Client::NetworkingError|Aws::S3::Errors::(?:ServiceError|InternalError|ServiceUnavailable|SlowDown|RequestTimeout))\z/
  TRANSIENT_MESSAGE_PATTERN = /connection refused|failed to open tcp connection|execution expired|timed out|temporarily unavailable|try again|econnrefused|econnreset|ehostunreach|enetunreach|etimedout/i

  Result = Data.define(:available, :service, :error_class, :message) do
    def as_json(*)
      {
        available: available,
        service: service,
        error_class: error_class,
        message: message
      }.compact
    end
  end

  def self.available?(service: ActiveStorage::Blob.service)
    new(service: service).available?
  end

  def self.check(service: ActiveStorage::Blob.service)
    new(service: service).check
  end

  def self.transient_error?(error)
    new.transient_error?(error)
  end

  def initialize(service: nil)
    @service = service
  end

  def available?
    check.available
  end

  def check
    storage = service
    storage.exist?(PROBE_KEY)
    Result.new(available: true, service: service_name(storage), error_class: nil, message: nil)
  rescue StandardError => e
    if transient_error?(e)
      Result.new(
        available: false,
        service: service_name(service),
        error_class: e.class.name,
        message: e.message.to_s
      )
    else
      raise
    end
  end

  def transient_error?(error)
    each_cause(error).any? do |cause|
      TRANSIENT_ERROR_CLASSES.any? { |klass| cause.is_a?(klass) } ||
        cause.class.name.match?(TRANSIENT_ERROR_NAME_PATTERN) ||
        cause.message.to_s.match?(TRANSIENT_MESSAGE_PATTERN)
    end
  end

  private

  attr_reader :service

  def each_cause(error)
    Enumerator.new do |yielder|
      current = error
      seen = {}
      while current && !seen[current.object_id]
        seen[current.object_id] = true
        yielder << current
        current = current.cause
      end
    end
  end

  def service_name(storage)
    storage.respond_to?(:name) ? storage.name.to_s : storage&.class&.name
  end
end
