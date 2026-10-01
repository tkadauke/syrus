require "rails_helper"

RSpec.describe CognitiveReview::DiffReviewAnnotationProvider do
  it "projects submitted workflow notes for the requested diff version into review annotations" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    note = CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 6,
      title: "Check lifecycle",
      explanation: "This range changes lifecycle behavior.",
      source_metadata: {}
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload.dig(:ranges, "app/models/job.rb")).to contain_exactly(
      hash_including(
        id: "cognitive_review_note:#{note.id}",
        component: "cognitive_review/note_marker",
        path: "app/models/job.rb",
        side: "new",
        start_line: 4,
        end_line: 6,
        title: "Check lifecycle",
        props: hash_including(
          note_id: note.id,
          job_id: job.id,
          path: "app/models/job.rb",
          explanation: "This range changes lifecycle behavior."
        )
      )
    )
    expect(payload[:panels]).to contain_exactly(
      hash_including(
        id: "cognitive_review.note.#{note.id}",
        component: "cognitive_review/note_panel",
        title: "Check lifecycle",
        body: "This range changes lifecycle behavior.",
        props: hash_including(hide_header: true, notes: [ hash_including(note_id: note.id) ], total: 1)
      )
    )
    expect(payload[:counts]).to contain_exactly(
      hash_including(id: "cognitive_review.open", label: "Review Notes", value: 1)
    )
  end

  it "omits same-range human-comment-handled notes from open review annotations" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    note = CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 6,
      title: "Check lifecycle",
      explanation: "This range changes lifecycle behavior.",
      source_metadata: {}
    )
    job.diff_review_comments.create!(
      user: job.user,
      diff_review_version: version,
      surface: "job_review_workspace",
      path: "app/models/job.rb",
      side: "right",
      new_line: 5,
      body: "I checked this range.",
      state: "draft"
    )
    job.diff_review_comments.create!(
      user: job.user,
      diff_review_version: version,
      surface: "job_review_workspace",
      path: "app/models/job.rb",
      side: "right",
      new_line: 9,
      body: "Different range.",
      state: "draft"
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload[:ranges]).to eq({})
    expect(payload[:panels]).to eq([])
    expect(payload[:counts]).to contain_exactly(hash_including(id: "cognitive_review.open", value: 0))
  end

  it "keeps older-version notes out of active inline annotations while exposing them to the sidebar" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    old_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "old-base",
      head_sha: "old-head",
      files: []
    )
    new_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: nil,
      base_sha: "new-base",
      head_sha: "new-head",
      files: []
    )
    note = CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: old_version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 4,
      title: "Old note",
      explanation: "This belongs to an older diff.",
      source_metadata: {}
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: new_version,
      base_sha: "new-base",
      head_sha: "new-head",
      files: []
    )

    expect(payload[:ranges]).to eq({})
    expect(payload[:panels]).to eq([])
    expect(payload[:counts]).to contain_exactly(hash_including(id: "cognitive_review.open", value: 0))
    expect(payload[:sidebar_counts]).to contain_exactly(hash_including(id: "cognitive_review.open", value: 1))
    expect(payload[:sidebar_panels]).to contain_exactly(
      hash_including(
        id: "cognitive_review.note.#{note.id}",
        diff_review_version_id: old_version.id,
        props: hash_including(diff_review_version_id: old_version.id, notes: [ hash_including(note_id: note.id) ])
      )
    )
  end

  it "counts acknowledged and discussed notes as handled rather than unresolved review-note debt" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 4,
      title: "Handled note",
      explanation: "Already handled.",
      state: "acknowledged",
      source_metadata: {}
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload[:ranges]).to eq({})
    expect(payload[:counts]).to contain_exactly(
      hash_including(id: "cognitive_review.open", label: "Review Notes", value: 0)
    )
  end
  it "counts user comments on covered note ranges as handled review-note debt" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    note = CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 6,
      title: "Commented note",
      explanation: "A user comment on this range handles it.",
      source_metadata: {}
    )
    DiffReviewComment.create!(
      job: job,
      diff_review_version: version,
      user: job.user,
      surface: "job_source_diff",
      anchor_kind: "line",
      path: note.path,
      side: "right",
      new_line: 5,
      body: "I'll inspect this edge.",
      state: "draft"
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload[:ranges]).to eq({})
    expect(payload[:counts]).to contain_exactly(hash_including(id: "cognitive_review.open", value: 0))
  end

  it "keeps notes open when user comments miss the covered range" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    note = CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 6,
      title: "Uncommented note",
      explanation: "A nearby comment should not handle this.",
      source_metadata: {}
    )
    DiffReviewComment.create!(
      job: job,
      diff_review_version: version,
      user: job.user,
      surface: "job_source_diff",
      anchor_kind: "line",
      path: note.path,
      side: "right",
      new_line: 7,
      body: "This is nearby, not covered.",
      state: "draft"
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload.dig(:ranges, note.path)).to contain_exactly(hash_including(id: "cognitive_review_note:#{note.id}"))
    expect(payload[:counts]).to contain_exactly(hash_including(id: "cognitive_review.open", value: 1))
  end

  it "uses preloaded discussion entries when rendering note props" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    user = Factories.user
    2.times do |index|
      note = CognitiveReview::Note.create!(
        job: job,
        workflow: workflow,
        run: run,
        diff_review_version: version,
        path: "app/models/job_#{index}.rb",
        side: "new",
        start_line: 4,
        end_line: 4,
        title: "Open note #{index}",
        explanation: "Still open, but with discussion history.",
        source_metadata: {}
      )
      CognitiveReview::DiscussionEntry.create!(note: note, user: user, body: "Earlier operator context #{index}")
    end

    discussion_selects = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      discussion_selects << sql if sql.match?(/\ASELECT\b/i) && sql.include?("cognitive_review_discussion_entries")
    end

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload.fetch(:panels).flat_map { |panel| panel.dig(:props, :notes) }.flat_map { |note| note[:discussion_entries] }.map { |entry| entry[:body] }).to contain_exactly(
      "Earlier operator context 0",
      "Earlier operator context 1"
    )
    expect(discussion_selects.size).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end
end
