require "rails_helper"
require "tmpdir"

RSpec.describe GraderInputMaterialization do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) { workflow.steps.create!(kind: "grader", position: 10, details: { "name" => "rspec" }) }
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration) }

  around do |example|
    Dir.mktmpdir("grader-input-materialization") do |dir|
      @workspace_path = Pathname.new(dir)
      example.run
    end
  end

  def call
    described_class.call(
      repository: job.repository,
      workflow: workflow,
      step: step,
      run: run,
      grader_name: "rspec",
      grader_definition: { "name" => "rspec" },
      workspace_path: @workspace_path,
      destination_path: ".syrus/parallel_runtime_rspec.log"
    )
  end

  it "calls registered providers with a generic grader context" do
    provider = Class.new do
      class << self
        attr_reader :seen_context

        def materialize_grader_inputs(context)
          @seen_context = context
        end
      end
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:grader_input_materializer).and_return([ provider ])

    call

    expect(provider.seen_context).to have_attributes(
      repository: job.repository,
      workflow: workflow,
      step: step,
      run: run,
      grader_name: "rspec",
      workspace_path: @workspace_path,
      destination_path: ".syrus/parallel_runtime_rspec.log"
    )
  end

  it "logs and continues when no provider is enabled" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:grader_input_materializer).and_return([])

    expect { call }.not_to raise_error

    expect(run.job_logs.where(kind: "system").pluck(:chunk).join).to include("no providers available")
  end

  it "logs and continues when a provider fails" do
    provider = Class.new do
      def self.materialize_grader_inputs(_context)
        raise "boom"
      end
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:grader_input_materializer).and_return([ provider ])

    expect { call }.not_to raise_error

    expect(run.job_logs.where(kind: "system").pluck(:chunk).join).to include("failed: RuntimeError: boom")
  end
end
