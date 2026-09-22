# Saving a failed Run's RunDiagnostic classifies the Run automatically (see
# RunDiagnostic#refresh_failure_classification!). A spec that wants a specific
# classification replaces that one rather than colliding with it -- the
# classification is unique per Run.
module RunFailureClassificationHelpers
  def replace_failure_classification!(run, **attributes)
    RunFailureClassification.where(run_id: run.id).delete_all
    run.reload.create_run_failure_classification!(**attributes)
  end
end

RSpec.configure do |config|
  config.include RunFailureClassificationHelpers
end
