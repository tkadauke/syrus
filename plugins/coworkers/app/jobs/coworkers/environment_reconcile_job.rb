class Coworkers::EnvironmentReconcileJob < Syrus::Host::PluginJob
  include SkipIfPending

  plugin :coworkers

  def perform
    Coworkers::EnvironmentReconciler.new.call.size
  end
end
