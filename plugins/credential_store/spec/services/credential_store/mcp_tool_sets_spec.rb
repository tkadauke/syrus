require "rails_helper"

RSpec.describe "CredentialStore MCP tool sets" do
  it "advertises SSH exec as a deferred chat tool" do
    tools = CredentialStore::ChatToolSet.tool_definitions(tier: :deferred)

    expect(tools.map { |tool| tool.fetch(:name) }).to eq([ "credential_store_ssh_exec" ])
    expect(tools.first.dig(:input_schema, :required)).to eq([ "credential", "host", "user", "command" ])
  end

  it "never advertises SSH exec to coworkers through any grant" do
    permanently_excluded = %w[credential_store_ssh_exec]
    definitions = CredentialStore::ChatToolSet.tool_definitions(tier: :deferred).index_by { |tool| tool.fetch(:name) }

    permanently_excluded.each do |tool_name|
      expect(definitions.fetch(tool_name)).not_to include(:coworker_safe, :capability)
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
  end
end
