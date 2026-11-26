class Coworkers::EnvironmentReconcileJob < Syrus::Host::BackgroundJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    Coworkers::EnvironmentReconciler.new.call
  end
end
