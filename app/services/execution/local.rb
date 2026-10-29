module Execution
  class Local < Backend
    def run(request)
      validate_request!(request)
      unless request.local_runner.respond_to?(:run_with_local_backend)
        raise InvalidRequest, "local_runner must implement #run_with_local_backend"
      end
      request.local_runner.run_with_local_backend
    end
  end
end
