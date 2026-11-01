require "rails_helper"

RSpec.describe "CredentialStore MCP tool sets" do
  it "advertises SSH exec as a deferred chat tool" do
    tools = CredentialStore::ChatToolSet.tool_definitions(tier: :deferred)

    expect(tools.map { |tool| tool.fetch(:name) }).to eq([ "credential_store_ssh_exec" ])
    expect(tools.first.dig(:input_schema, :required)).to eq([ "credential", "host", "user", "command" ])
    expect(tools.first.fetch(:capability_descriptor)).to have_attributes(
      capability: "ssh.execute@v1", operation: "ssh.execute/risky@v1"
    )
  end

  it "never advertises SSH exec to coworkers through any grant" do
    permanently_excluded = %w[credential_store_ssh_exec]
    definitions = CredentialStore::ChatToolSet.tool_definitions(tier: :deferred).index_by { |tool| tool.fetch(:name) }
    registered_grant_tools = Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set).flat_map do |provider|
      provider.respond_to?(:coworker_grants) ? provider.coworker_grants.flat_map { |grant| grant.fetch(:tools) } : []
    end

    permanently_excluded.each do |tool_name|
      expect(definitions.fetch(tool_name)).not_to include(:coworker_safe, :capability)
      expect(registered_grant_tools).not_to include(tool_name)
    end
    expect(CredentialStore::ChatToolSet).not_to respond_to(:coworker_grants)
  end

  it "advertises SSH exec to workflow agents" do
    user = Factories.user
    repository = Factories.repository(user: user)
    run = Factories.job_with_run(user: user, repository: repository).runs.first
    context = McpToolContext.from_run(run)

    expect(CredentialStore::WorkflowToolSet.tool_definitions(context: context).map { |tool| tool.fetch(:name) })
      .to eq([ "credential_store_ssh_exec" ])
    expect(CredentialStore::WorkflowToolSet.tool_definitions(context: context).first.fetch(:capability_descriptor))
      .to have_attributes(capability: "ssh.execute@v1")
  end
end
