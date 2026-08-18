module Admin
  # Writes the Rails.cache "poison pill" that RestartWatcher polls for.
  # Shared by the bearer-token admin API (Api::V1::Admin::RestartController)
  # and the session-authenticated SPA API (Api::V1::App::Admin::RestartController),
  # same split as Admin::Console::Payload.
  class RestartService
    COMPONENTS = %w[ web worker all ].freeze
    POISON_PILL_TTL = 5.minutes

    class InvalidComponent < ArgumentError; end

    def initialize(actor:)
      @actor = actor
    end

    def active_run_count
      Run.active.count
    end

    def request(component:, force: false, source:)
      component = component.to_s
      raise InvalidComponent, component unless COMPONENTS.include?(component)

      active_runs = active_run_count
      if restarts_worker?(component) && active_runs.positive? && !force
        return { initiated: false, component: component, active_runs: active_runs }
      end

      roles_for(component).each { |role| write_poison_pill(role) }
      AdminAction.log!(
        user: actor,
        action: :restart,
        params: { component: component, source: source, force: force, active_runs: active_runs }
      )

      { initiated: true, component: component, active_runs: active_runs }
    end

    private

    attr_reader :actor

    def restarts_worker?(component)
      component == "worker" || component == "all"
    end

    def roles_for(component)
      component == "all" ? %w[ web worker ] : [ component ]
    end

    def write_poison_pill(role)
      Rails.cache.write("syrus:restart_#{role}", Time.now.utc.to_f, expires_in: POISON_PILL_TTL)
    end
  end
end
