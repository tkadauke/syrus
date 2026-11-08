require "rails_helper"

RSpec.describe "Coworker journaling with mixed encodings" do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-encoding", workspace_repo: repository.remote_url)
  end
  let(:chat) do
    ChatSession.create!(user: owner, repository: repository, title: "Maya").tap do |session|
      Coworkers::Chat.create!(coworker: coworker, chat_session: session, role: "main")
    end
  end
  let(:date) { Date.new(2026, 11, 5) }

  before do
    PluginRecord.find_or_create_by!(name: "coworkers").update!(enabled: true, disableable: true)
  end

  def add_message(text)
    chat.messages.create!(role: "user", content: [ { "type" => "text", "text" => text } ], skip_turn_trigger: true,
                          created_at: Time.utc(2026, 11, 5, 12))
  end

  def stub_daily_memory(raw)
    reader = instance_double(RepositoryContent::Reader)
    allow(RepositoryContent).to receive(:for).and_return(reader)
    allow(reader).to receive(:resolve).and_return("rev")
    allow(reader).to receive(:read).and_return(double(text: raw))
  end

  def reconciled_schedule
    allow(ScheduledTasks::SystemSchedules).to receive(:fetch).with("journaling").and_return(Coworkers::Prompts::Journaling)
    Coworkers::SystemSchedules.reconcile!(coworker).tap do |task|
      allow(task).to receive(:system_schedule_definition).and_return(Coworkers::Prompts::Journaling.new)
    end
  end

  def material = Coworkers::JournalingActivity.new(coworker:, date:).material

  it "joins binary daily memory with non-ASCII UTF-8 messages (the production raise)" do
    add_message("Café über alles ✓")
    stub_daily_memory("Notiz \xC3\xBCber Caf\xC3\xA9".b)

    result = nil
    expect { result = material }.not_to raise_error
    expect(result.encoding).to eq(Encoding::UTF_8)
    expect(result).to be_valid_encoding
    expect(result).to include("Notiz über Café", "Café über alles ✓")
    expect(result).not_to include("undecodable")
  end

  it "replaces invalid UTF-8 and notes that content was undecodable" do
    add_message("ok")
    stub_daily_memory("bad \xFF\xFE bytes".b)

    result = material

    expect(result).to be_valid_encoding
    expect(result).to include("bad �� bytes", "undecodable")
  end

  it "summarizes true binary blobs by size instead of injecting them" do
    add_message("ok")
    stub_daily_memory("\x89PNG\r\n\x00\x00\xFF".b)

    result = material

    expect(result).to include("binary content omitted", "memory/daily/2026-11-05.md", "9 bytes")
    expect(result).not_to include("PNG")
  end

  it "tolerates empty strings" do
    add_message("")
    stub_daily_memory("")

    expect(material).to be_valid_encoding
  end

  it "builds the journaling prompt for a binary-containing day" do
    add_message("Grüße")
    stub_daily_memory("Gr\xC3\xBC\xC3\x9Fe".b)
    journaling = reconciled_schedule

    prompt = nil
    expect { prompt = journaling.prompt_for(target_date: date) }.not_to raise_error
    expect(prompt).to be_valid_encoding
  end

  it "journals missed days in order through the real fire path and clears the failed state" do
    add_message("Café")
    stub_daily_memory("Caf\xC3\xA9".b)
    journaling = reconciled_schedule
    journaling.update_columns(created_at: Time.utc(2026, 11, 3, 9), last_journaled_on: Date.new(2026, 11, 3))
    journaling.record_system_result!(date: Date.new(2026, 11, 4), result: "failed", reason: "Encoding::CompatibilityError: x")
    journaling.update_columns(last_journaled_on: Date.new(2026, 11, 3))
    workflow = instance_double(Workflow, set_artifact!: nil)
    allow(WorkUnits::Launcher).to receive(:instantiate).and_return(workflow)
    allow(WorkUnits::Launcher).to receive(:start!)

    travel_to(Time.utc(2026, 11, 6, 3, 15)) do
      handler = Coworkers::ScheduledTaskFireHandler.new(journaling)
      job = handler.fire_journaling_catch_up!(now: Time.current, remaining: 7)
      expect(job.issue_title).to include("for 2026-11-04")
      expect(job.issue_body).to be_valid_encoding
      journaling.record_system_result!(date: Date.new(2026, 11, 4), result: "journaled")
    end

    journaling.reload
    expect(journaling.last_journaled_on).to eq(Date.new(2026, 11, 4))
    expect(journaling.system_result_history.map { |e| e["result"] }).not_to include("failed")
    expect(Coworkers::SystemSchedules.target_dates(journaling, now: Time.utc(2026, 11, 6, 3, 15))).to eq([ Date.new(2026, 11, 5) ])
  end

  it "records the first backtrace frame with a failed journal date" do
    journaling = reconciled_schedule
    journaling.update_columns(last_journaled_on: nil, created_at: Time.utc(2026, 11, 3, 9))
    error = begin
      "é" + "\xFF".b
    rescue Encoding::CompatibilityError => e
      e
    end

    journaling.record_fire_failure!(error, at: Time.utc(2026, 11, 4, 3, 15))

    expect(journaling.reload.last_system_result_reason)
      .to match(/\AEncoding::CompatibilityError: .+ \(at .*journaling_encoding_spec\.rb:\d+/)
    expect(journaling.system_result_history.last["reason"]).to eq(journaling.last_system_result_reason)
  end
end
