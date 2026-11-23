module WorkflowJudgeStubs
  def stub_no_workflow_judges
    allow(Workflows::CompositionAnchors).to receive(:judges).and_return([])
  end

  def stub_workflow_judge(step_kind:, rounds: 1, agent_step: :implement)
    loop_node = Workflows::Loop.new(max_iterations: rounds, steps: [ agent_step, step_kind ])
    allow(Workflows::CompositionAnchors).to receive(:judges).and_return([ loop_node ])
  end
end

RSpec.configure do |config|
  config.include WorkflowJudgeStubs
end
