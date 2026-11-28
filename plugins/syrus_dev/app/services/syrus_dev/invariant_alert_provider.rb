module SyrusDev
  # Syrus-developer diagnostics: the invariant monitor's open violations as an
  # admin banner, shown only on instances that enable this plugin.
  class InvariantAlertProvider
    include Syrus::Host::SystemAlertProvider

    def self.system_alerts
      [ Syrus::Host::Invariants.open_violations_alert ].compact
    end
  end
end
