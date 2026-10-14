require "rails_helper"

RSpec.describe AdminMysql::StatusTool do
  it "refuses direct invocation from a non-admin context" do
    context = instance_double(McpToolContext, user: instance_double(User, admin?: false))
    allow(McpToolContext).to receive(:from_server_context).and_return(context)
    expect(AdminMysql::Inspector).not_to receive(:new)

    response = described_class.call(server_context: { run_id: 1 })

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unauthorized")
  end

  it "reads status when invoked from an admin context" do
    context = instance_double(McpToolContext, user: instance_double(User, admin?: true))
    allow(McpToolContext).to receive(:from_server_context).and_return(context)
    payload = { process_list: [] }
    inspector = instance_double(AdminMysql::Inspector, snapshot: payload)
    allow(AdminMysql::Inspector).to receive(:new).and_return(inspector)

    response = described_class.call(server_context: { run_id: 1 }, limit: 5)

    expect(response.error?).to be(false)
    expect(response.content.first[:text]).to eq(JSON.pretty_generate(payload))
    expect(inspector).to have_received(:snapshot).with(limit: 5)
  end
end
