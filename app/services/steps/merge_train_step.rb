module Steps
  # Shared helpers for the Epic merge-train steps. The MergeTrain row is
  # created by the dispatcher (LandingQueueProcessor) and referenced from
  # the Workflow's artifacts under "merge_train_id".
  module MergeTrainStep
    private

    def merge_train
      @merge_train ||= begin
        id = workflow.artifact("merge_train_id")
        raise Base::StepFailed, "merge_train: workflow has no merge_train_id artifact" if id.blank?

        train = MergeTrain.find_by(id: id) ||
          raise(Base::StepFailed, "merge_train: MergeTrain ##{id} not found")
        if train.terminal?
          raise Base::StepFailed, "merge_train: MergeTrain ##{id} is #{train.state}; rebuild required"
        end

        train
      end
    end

    def epic
      merge_train.epic
    end

    # LandedCommit attribution target for train-level (not per-member)
    # commits: the Epic for an Epic-backed train, the MergeTrain itself for a
    # bundle-backed train (there's no Epic to attach to). nil is unreachable
    # in practice -- MergeTrain validates it is always exactly one of the two.
    def landed_commit_landable(train)
      return train.epic if train.epic_backed?
      return train if train.bundle_backed?

      nil
    end
  end
end
