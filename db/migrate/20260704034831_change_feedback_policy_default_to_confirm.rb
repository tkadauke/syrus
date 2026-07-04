class ChangeFeedbackPolicyDefaultToConfirm < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:repositories, :feedback_policy)

    change_column_default :repositories, :feedback_policy, from: "auto", to: "confirm"
  end

  def down
    return unless column_exists?(:repositories, :feedback_policy)

    change_column_default :repositories, :feedback_policy, from: "confirm", to: "auto"
  end
end
