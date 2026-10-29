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
      raise InvalidRequest, "timeout must be positive" unless Float(request.timeout).positive?
      request
    rescue KeyError, ArgumentError => error
      raise if error.is_a?(InvalidRequest)
      raise InvalidRequest, error.message
    end
  end
end
