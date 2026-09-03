module TestInsights
  # What used to be `Run has_many :test_runs, dependent: :destroy` and
  # `Repository has_many :test_identities, dependent: :destroy`, injected onto
  # core models at boot.
  #
  # Registered through Syrus::Installer *without* a `plugin:` scope on purpose:
  # disabling this plugin hides the Tests UI, it does not delete the rows, and
  # those rows must still go when their run or repository does.
  module DataCleanup
    def self.install!
      Syrus::Installer.define("test_insights:data_cleanup") do |scope|
        scope.effect("run test results") do
          Syrus::DataCleanup.register("Run", "test_insights.test_runs") do |run|
            TestInsights::TestRun.for_run(run).find_each(&:destroy)
          end
        end

        scope.effect("repository test identities") do
          Syrus::DataCleanup.register("Repository", "test_insights.test_identities") do |repository|
            TestInsights::TestIdentity.for_repository(repository).find_each(&:destroy)
          end
        end
      end
    end
  end
end
