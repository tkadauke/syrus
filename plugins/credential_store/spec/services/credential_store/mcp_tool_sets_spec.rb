require "rails_helper"

RSpec.describe "CredentialStore MCP tool sets" do
  it "advertises SSH exec as a deferred chat tool" do
    tools = CredentialStore::ChatToolSet.tool_definitions(tier: :deferred)

    expect(tools.map { |tool| tool.fetch(:name) }).to eq([ "credential_store_ssh_exec" ])
    expect(tools.first.dig(:input_schema, :required)).to eq([ "credential", "host", "user", "command" ])
  end

  it "advertises SSH exec to workflow agents" do
    user = Factories.user
    repository = Factories.repository(user: user)
    run = Factories.job_with_run(user: user, repository: repository).runs.first
    context = McpToolContext.from_run(run)

    expect(CredentialStore::WorkflowToolSet.tool_definitions(context: context).map { |tool| tool.fetch(:name) })
      .to eq([ "credential_store_ssh_exec" ])
  end
end
