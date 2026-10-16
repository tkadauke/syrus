module Terminal
  class OrphanReaperJob < ApplicationJob
    queue_as :cleanup

    def perform
      OrphanReaper.run!
    end
  end
end
