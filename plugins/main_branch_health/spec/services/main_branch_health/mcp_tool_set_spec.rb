require "rails_helper"

RSpec.describe MainBranchHealth::McpToolSet do
  let(:user) { Factories.user }

  def names(context) = described_class.tool_definitions(context: context).map { |tool| tool[:name] }

  it "offers report_main_concern to implementation roles" do
    context = McpToolContext.from_run(Factories.job.initial_run)

    expect(names(context)).to eq([ "report_main_concern" ])
  end

  it "withholds report_main_concern from reviewer roles, which cannot tell main regressions from infrastructure noise" do
    [ AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, AgentRole::WORKFLOW_VISUAL_REVIEWER ].each do |role|
      context = McpToolContext.new(surface: :run, role: role, user: user)

      expect(names(context)).to eq([])
    end
  end

  it "registers its capability with the permission provider" do
    expect(MainBranchHealth::PermissionProvider::OPERATIONS).to include("report_main_concern")
  end
end
