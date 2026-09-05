module PendingActionGroups
  MemberResult = Data.define(:pending_action, :success, :error) do
    def success? = success
    def failure? = !success
  end
end
