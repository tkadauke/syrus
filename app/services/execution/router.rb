module Execution
  class Router < Backend
    class BackendUnavailable < StandardError; end
    class NotAuthorized < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super("execution #{result.policy} for #{result.subject.location} process")
      end
    end

    # +authorizer+ is a callable taking the request and the backend location
    # (+location:+ of +:host+ or +:container+) and returning a
    # +Permissions::ExecutionAuthorization::Result+, or nil for "no opinion".
    # The default is +Permissions::ExecutionGate+. Any result other than an
    # explicit allow raises +NotAuthorized+ before a process starts. Raw
    # process execution has no exact-invocation replay boundary, so an +ask+
    # must fail closed instead of being logged and treated as approval.
    def initialize(local: Local.new, authorizer: Permissions::ExecutionGate.new)
      @local = local
      @authorizer = authorizer
    end

    def run(request)
      validate_request!(request)
      backend = backend_for(request)
      authorization = authorize!(request, backend)
      request = with_authority_commit(request, authorization)
      WorkspaceReuseOutcomes::Recorder.note_backend(run: request.run, backend: backend_identity(backend))
      backend.run(request)
    rescue StandardError
      authorization&.reservation&.release!
      raise
    end

    private

    attr_reader :local, :authorizer

    def authorize!(request, backend)
      location = backend.is_a?(Execution::Local) ? :host : :container
      result = authorizer&.call(request, location:)
      return unless result
      raise NotAuthorized, result unless result.allowed?

      result
    end

    def with_authority_commit(request, authorization)
      return request unless authorization&.reservation

      callback = request.on_spawned_process
      request.with(on_spawned_process: lambda do |process|
        authorization.reservation.commit!
        callback&.call(process)
      end)
    end

    def backend_identity(backend)
      return "local" if backend.is_a?(Execution::Local)

      name = backend.class.name.to_s
      name.deconstantize.presence&.underscore || name.presence&.underscore || "custom"
    end

    def backend_for(request)
      provider = Syrus::PluginRegistry.providers_for(:execution_backend).find do |candidate|
        candidate.available_for?(request)
      end
      return provider.is_a?(Class) ? provider.new : provider if provider
      raise BackendUnavailable, "no execution backend is available for #{request.workload_policy.name}" if fail_closed?(request)

      local
    rescue ActiveRecord::ActiveRecordError
      raise BackendUnavailable, "execution backend availability could not be verified" if fail_closed?(request)
      local
    end

    def fail_closed?(request) = request.workload_policy&.fail_closed? == true
  end
end
