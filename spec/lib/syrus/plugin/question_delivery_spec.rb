require "rails_helper"

RSpec.describe "question delivery capability", :reset_plugin_registry do
  before { Syrus::Plugin::Family.restore(Syrus::Plugin::Families::QuestionDelivery) }

  it "lets a plugin answer through the shared service and broadcasts the winning closure" do
    user = Factories.user
    job = Factories.job(user:)
    run = job.initial_run
    workflow = run.workflow
    workflow.update_columns(state: "running", started_at: 1.minute.ago)
    run.step.update_columns(state: "awaiting_answer", started_at: 1.minute.ago)
    run.update_columns(state: "awaiting_answer", started_at: 1.minute.ago)
    events = []
    provider = Class.new do
      define_singleton_method(:key) { "fake" }
      define_singleton_method(:display_name) { "Fake question channel" }
      define_singleton_method(:question_events) do |context|
        events << context
        if context.event_type == "asked"
          Syrus::Host::QuestionDelivery.answer(question_id: context.question_id, answers: [ "Safe" ],
            answered_by: user, source: "fake_channel")
        end
        nil
      end
    end
    stub_const("FakeQuestionChannel", provider)
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false,
      requires_syrus: nil, name: "fake_question_channel", version: "1", provides: {}, family_provides: [
        Syrus::Plugin::FamilyDeclaration.build(family: :question_delivery,
          provider: "FakeQuestionChannel", provisional: [ :question_events ])
      ])
    allow_any_instance_of(Run).to receive(:reenqueue!)

    question = AgentQuestion.create!(run:, asked_at: Time.current,
      questions: [ { "question" => "Which path?", "options" => nil, "multiple" => false } ])

    expect(question.reload).to have_attributes(answers: [ "Safe" ], answer_source: "fake_channel")
    expect(run.reload).to be_queued
    expect(events.map(&:event_type)).to eq(%w[asked answered])
    expect(Syrus::Host::QuestionDelivery.answer(question_id: question.id, answers: [ "Fast" ],
      answered_by: user, source: "other_channel")).to eq(false)
    expect(events.last).to have_attributes(event_type: "answered", active: false, answer_source: "fake_channel")
  end
end
