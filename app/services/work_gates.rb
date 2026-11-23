module WorkGates
  Result = Data.define(:vetoes) do
    def pass? = vetoes.empty?
    def veto? = !pass?
    def first = vetoes.first
    def veto_for(reason) = vetoes.find { |veto| veto.reason == reason.to_s }
  end

  def self.evaluate(workflow: nil, work_unit: nil, job: nil, landing: false)
    context = Syrus::Plugin::Context::WorkContext.new(workflow:, work_unit:, job:, landing:)
    vetoes = Syrus::Plugin::Dispatch.call(:work_policy, :work_gate, context)
    Result.new(vetoes: Array(vetoes).compact.freeze)
  end
end
