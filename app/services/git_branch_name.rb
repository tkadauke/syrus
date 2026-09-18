module GitBranchName
  module_function

  def normalize(branch_name)
    branch_name.to_s.strip.presence
  end

  def valid?(branch_name)
    return false if branch_name.blank?
    return false if branch_name.start_with?("/", "-") || branch_name.end_with?("/", ".")
    return false if branch_name.include?("//") || branch_name.include?("..")
    return false if branch_name.end_with?(".lock")
    return false if branch_name.split("/").any? { |part| part.blank? || part.start_with?(".") }

    !branch_name.match?(/[[:space:]~^:?*\[\\]/)
  end
end
