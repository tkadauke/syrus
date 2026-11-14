require "rails_helper"

RSpec.describe "Coworker proposer dashboard filtering" do
  it "filters Jobs and Epics through the core proposer chip" do
    owner = Factories.user(email_address: "owner@example.com")
    repository = Factories.repository(user: owner, owner: "acme", name: "widgets")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner,
      name: "Adrian",
      handle: "adrian-filter",
      workspace_repo: repository.remote_url
    )
    proposed_job = Factories.job_record(user: owner, repository: repository, proposer: coworker)
    Factories.job_record(user: owner, repository: repository)
    proposed_epic = Factories.epic(user: owner, repository: repository, proposer: coworker)
    Factories.epic(user: owner, repository: repository)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:mentionable).and_return([ Coworkers::MentionableProvider ])
    tree = Filters::Ast.parse("field" => "proposer", "op" => "is", "value" => coworker.handle)

    jobs = Filters::Compiler.call(tree, scope: Job.where(repository: repository), user: owner, subject: :job)
    epics = Filters::Compiler.call(tree, scope: Epic.where(repository: repository), user: owner, subject: :epic)

    expect(jobs).to contain_exactly(proposed_job)
    expect(epics).to contain_exactly(proposed_epic)
  end
end
