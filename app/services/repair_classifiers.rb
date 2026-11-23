module RepairClassifiers
  def self.classify(workflow: nil, run: nil, failed_steps: [])
    context = Syrus::Plugin::Context::RepairContext.new(workflow:, run:, failed_steps:)
    Syrus::Plugin::Dispatch.call(:work_policy, :repair_classifier, context)
  end
end
