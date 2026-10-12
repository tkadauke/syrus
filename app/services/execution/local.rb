module Execution
  class Local < Backend
    def run(request)
      request.local_runner.run_with_local_backend
    end
  end
end
