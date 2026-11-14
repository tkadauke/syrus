require "rails_helper"

RSpec.describe Filters::Chips::Proposer do
  let(:user) { Factories.user(email_address: "operator@example.com") }
  let(:human) { Factories.user(email_address: "adrian@example.com") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def filter(subject:, op:, value: nil)
    model = subject == :job ? Job : Epic
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "proposer", "op" => op, "value" => value),
      scope: model.where(repository: repository),
      user: user,
      subject: subject
    )
  end

  it "filters Jobs and Epics by a human proposer and clearing restores the full scope" do
    human_job = Factories.job_record(user: user, repository: repository, proposer: human)
    other_job = Factories.job_record(user: user, repository: repository)
    human_epic = Factories.epic(user: user, repository: repository, proposer: human)
    other_epic = Factories.epic(user: user, repository: repository)

    expect(filter(subject: :job, op: "is", value: human.handle)).to contain_exactly(human_job)
    expect(filter(subject: :epic, op: "is", value: human.handle)).to contain_exactly(human_epic)
    expect(Job.where(repository: repository)).to contain_exactly(human_job, other_job)
    expect(Epic.where(repository: repository)).to contain_exactly(human_epic, other_epic)
  end

  it "exposes human and provider-contributed mentionables as filter options" do
    human
    coworker = Struct.new(:kind, :mentionable_id, :display_name, :handle).new("coworker", 7, "Adrian", "adrian-qa")
    provider = Class.new do
      define_singleton_method(:share_candidates) { |user:| [ coworker ] }
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:mentionable).and_return([ provider ])

    values = described_class.schema_values(user)

    expect(values).to include(
      { "value" => human.handle, "label" => "#{human.display_name} (@#{human.handle})" },
      { "value" => "adrian-qa", "label" => "Adrian (@adrian-qa)" }
    )
  end

  it "supports presence operators and an unknown handle" do
    proposed = Factories.job_record(user: user, repository: repository, proposer: human)
    unproposed = Factories.job_record(user: user, repository: repository)

    expect(filter(subject: :job, op: "is_set")).to contain_exactly(proposed)
    expect(filter(subject: :job, op: "is_unset")).to contain_exactly(unproposed)
    expect(filter(subject: :job, op: "is", value: "nobody-here")).to be_empty
  end
end
