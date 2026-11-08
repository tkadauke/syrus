require "rails_helper"

RSpec.describe ChatMessageWindow do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository:) }
  let(:scope) { ChatMessage.active.where(chat_session_id: chat.id) }

  def say(text, role: "user")
    chat.messages.create!(role: role, content: { "text" => text })
  end

  def tool_call(tool: "read_run_transcript", result: "ok")
    use = chat.messages.create!(role: "tool_use", tool_name: tool, content: { "text" => "calling #{tool}" })
    done = chat.messages.create!(role: "tool_result", tool_name: tool, content: { "text" => result })
    [ use, done ]
  end

  it "reaches past a run of tool calls that the stream collapses into one row" do
    say("where did the run fail?")
    40.times { tool_call }
    say("here is what I found", role: "assistant")

    messages, has_more_older = described_class.new(scope, row_target: 3).call

    # The run is one row, so a row-counted window keeps walking back through
    # all 80 tool messages to find the two rows on either side of it. Counting
    # messages instead would have stopped inside the run and rendered one card.
    expect(messages.size).to eq(82)
    expect(messages.first.content.fetch("text")).to eq("where did the run fail?")
    expect(has_more_older).to be(false)
  end

  it "stops at the row target for ordinary messages" do
    60.times { |n| say("note #{n}") }

    messages, has_more_older = described_class.new(scope, row_target: 40).call

    expect(messages.size).to eq(40)
    expect(messages.last.content.fetch("text")).to eq("note 59")
    expect(has_more_older).to be(true)
  end

  it "counts a tool run as one row only while it is unbroken" do
    tool_call
    say("and then?", role: "assistant")
    tool_call

    messages, has_more_older = described_class.new(scope, row_target: 2).call

    # Newest first: the trailing run is one row, the assistant message is the
    # second, and the window stops there rather than swallowing the older run.
    expect(messages.size).to eq(3)
    expect(has_more_older).to be(true)
  end

  it "closes the window before an outsized tool result rather than shipping it" do
    say("read the transcript")
    tool_call(result: "x" * 20_000)
    20.times { |n| say("note #{n}") }

    messages, has_more_older = described_class.new(scope, row_target: 40, max_bytes: 10_000).call

    # The budget is a ceiling, so the result that would cross it ends the
    # window instead of joining it: a megabyte of transcript buys one row, and
    # paying for it would only cost bytes the reader gets nothing for.
    expect(messages.map { |message| message.content.fetch("text") }).to eq(20.times.map { |n| "note #{n}" })
    expect(has_more_older).to be(true)
  end

  it "always returns at least one message even when it alone exceeds the budget" do
    say("small")
    say("y" * 40_000)

    messages, has_more_older = described_class.new(scope, max_bytes: 1_000).call

    expect(messages.size).to eq(1)
    expect(messages.first.content.fetch("text")).to eq("y" * 40_000)
    expect(has_more_older).to be(true)
  end

  it "never exceeds the message ceiling however few rows it has found" do
    100.times { tool_call }

    messages, has_more_older = described_class.new(scope, row_target: 40, max_messages: 25).call

    expect(messages.size).to eq(25)
    expect(has_more_older).to be(true)
  end

  it "walks back from a cursor and reports when the history is exhausted" do
    oldest = say("oldest")
    middle = say("middle")
    newest = say("newest")

    messages, has_more_older = described_class.new(scope, row_target: 40).call(before: newest.id)

    expect(messages.map(&:id)).to eq([ oldest.id, middle.id ])
    expect(has_more_older).to be(false)
  end

  it "reports no older messages for an empty chat" do
    messages, has_more_older = described_class.new(scope).call

    expect(messages).to be_empty
    expect(has_more_older).to be(false)
  end

  it "skips soft-deleted messages because the scope excludes them" do
    say("kept")
    say("dropped").update!(deleted_at: Time.current)

    messages, _has_more_older = described_class.new(scope).call

    expect(messages.map { |message| message.content.fetch("text") }).to eq([ "kept" ])
  end
end
