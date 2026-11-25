# Compares runtime image records with what each provider stores and repairs
# drift (see RuntimeImages::Reconciler). Orphan removal is never automatic.
class RuntimeImageReconcileJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    findings = RuntimeImages::Reconciler.new.call
    Rails.logger.info("[RuntimeImageReconcileJob] findings=#{findings.size} " \
                      "kinds=#{findings.group_by(&:kind).transform_values(&:size).to_json}")
    findings.size
  end
end
