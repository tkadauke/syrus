import type { Dispatch, SetStateAction } from "react"
import { Checkbox } from "../../../../../app/frontend/components/Checkbox"
import { useT } from "../../../../../app/frontend/hooks/useT"
import type { RepositoryInput } from "../../../../../app/frontend/api/repositories"

type Props = {
  values: RepositoryInput
  setValues: Dispatch<SetStateAction<RepositoryInput>>
  setRepairTouched: Dispatch<SetStateAction<boolean>>
}

export default function RepositorySettings({ values, setValues, setRepairTouched }: Props) {
  const { t } = useT("settings")

  return (
    <>
      <Checkbox
        label={t("repository_form.check_main_health")}
        onChange={(event) => {
          const checked = event.target.checked
          setValues({
            ...values,
            main_branch_health_enabled: checked,
            main_branch_repair_enabled: checked ? values.main_branch_repair_enabled : false,
            main_branch_repair_blocks_work: checked ? values.main_branch_repair_blocks_work : false,
            main_branch_repair_auto_approve: checked ? values.main_branch_repair_auto_approve : false
          })
        }}
        checked={values.main_branch_health_enabled}
      />
      <Checkbox
        label={t("repository_form.check_main_repair")}
        onChange={(event) => {
          const checked = event.target.checked
          setRepairTouched(true)
          setValues({
            ...values,
            main_branch_health_enabled: checked ? true : values.main_branch_health_enabled,
            main_branch_repair_enabled: checked,
            main_branch_repair_auto_approve: checked ? values.main_branch_repair_auto_approve : false
          })
        }}
        checked={values.main_branch_health_enabled && values.main_branch_repair_enabled}
      />
      <Checkbox
        label={t("repository_form.check_main_repair_blocks_work")}
        onChange={(event) => {
          const checked = event.target.checked
          setValues({ ...values, main_branch_health_enabled: checked ? true : values.main_branch_health_enabled, main_branch_repair_blocks_work: checked })
        }}
        checked={values.main_branch_repair_blocks_work}
      />
      <Checkbox
        label={t("repository_form.check_repair_auto_approve")}
        onChange={(event) => {
          const checked = event.target.checked
          setValues({
            ...values,
            main_branch_health_enabled: checked ? true : values.main_branch_health_enabled,
            main_branch_repair_enabled: checked ? true : values.main_branch_repair_enabled,
            main_branch_repair_auto_approve: checked
          })
        }}
        checked={values.main_branch_health_enabled && values.main_branch_repair_enabled && values.main_branch_repair_auto_approve}
      />
    </>
  )
}
