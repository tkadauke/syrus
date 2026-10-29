module Execution
  class Backend
    CONTRACT_VERSION = "1.0".freeze
    class InvalidRequest < ArgumentError; end

    def run(_request)
      raise NotImplementedError, "#{self.class.name} must implement #run"
    end

    private

    def validate_request!(request)
      raise InvalidRequest, "request must be an Execution::Request" unless request.is_a?(Request)
      raise InvalidRequest, "command must be a non-empty array" unless request.command.is_a?(Array) && request.command.any?
      raise InvalidRequest, "mounts must be ProcessRunner::Mounts" unless request.mounts.is_a?(ProcessRunner::Mounts)
      ProcessRunner::NetworkProfile.for(request.network)
      if request.resource_limits && !request.resource_limits.is_a?(ResourceLimits)
        raise InvalidRequest, "resource_limits must be Execution::ResourceLimits"
      end
      validate_resource_limits!(request.resource_limits) if request.resource_limits
      raise InvalidRequest, "timeout must be positive" unless Float(request.timeout).positive?
      request
    rescue KeyError, ArgumentError => error
      raise if error.is_a?(InvalidRequest)
      raise InvalidRequest, error.message
    end

    def validate_resource_limits!(limits)
      if limits.memory_max && !Integer(limits.memory_max).positive?
        raise InvalidRequest, "memory_max must be a positive integer"
      end
      if limits.cpu_max
        quota, period = limits.cpu_max.to_s.split(/\s+/, 2).map { |value| Integer(value) }
        raise InvalidRequest, "cpu_max must contain a positive quota and period" unless quota&.positive? && period&.positive?
      end
      if limits.io_weight && !Integer(limits.io_weight).between?(10, 1000)
        raise InvalidRequest, "io_weight must be between 10 and 1000"
      end
    rescue ArgumentError, TypeError
      raise InvalidRequest, "resource limit values are malformed"
    end
  end
end
