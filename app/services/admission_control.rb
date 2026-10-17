class AdmissionControl
  def self.enabled?
    AppSetting.workflow_admission_control_enabled?
  end
end
