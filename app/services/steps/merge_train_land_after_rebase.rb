module Steps
  # Final landing step after a merge_train_rebase recovered from a moved base.
  # Identical to MergeTrainLand — reusing the same push + merge + reconcile
  # logic with the updated integration branch tip.
  class MergeTrainLandAfterRebase < MergeTrainLand
  end
end
