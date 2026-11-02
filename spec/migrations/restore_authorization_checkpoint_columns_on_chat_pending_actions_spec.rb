require "rails_helper"
require Rails.root.join("db/migrate/20261102142348_restore_authorization_checkpoint_columns_on_chat_pending_actions")

RSpec.describe RestoreAuthorizationCheckpointColumnsOnChatPendingActions do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:columns) do
    %w[
      checkpoint_state checkpoint_payload checkpointed_at resume_started_at
      resumed_at resume_attempts last_resume_error
    ]
  end

  after do
    migration.up
    ChatPendingAction.reset_column_information
  end

  it "restores the checkpoint schema omitted from fresh schema loads" do
    migration.down
    expect(columns).to all(satisfy { |column| !connection.column_exists?(:chat_pending_actions, column) })

    migration.up
    migration.up
    ChatPendingAction.reset_column_information

    expect(columns).to all(satisfy { |column| connection.column_exists?(:chat_pending_actions, column) })
    expect(ChatPendingAction.new.checkpoint_payload).to eq({})
    expect(connection.index_exists?(
      :chat_pending_actions,
      [ :origin_type, :origin_id, :checkpoint_state ],
      name: "idx_pending_actions_origin_checkpoint"
    )).to be(true)
  end
end
