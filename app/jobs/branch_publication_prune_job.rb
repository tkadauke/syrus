class BranchPublicationPruneJob < ApplicationJob
  queue_as :cleanup

  def perform
    BranchPublication.prunable.in_batches(of: 1_000).delete_all
  end
end
