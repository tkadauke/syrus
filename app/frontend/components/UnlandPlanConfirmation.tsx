import { Notice } from "./ui"

interface UnlandPlanConfirmationProps {
  subject: string
  details: string[]
  deploymentWarning: string
  warnings: string[]
}

export function UnlandPlanConfirmation({ subject, details, deploymentWarning, warnings }: UnlandPlanConfirmationProps) {
  return (
    <div className="space-y-4 text-sm text-text-secondary">
      <p className="font-medium text-text-primary">{subject}</p>
      <ul className="divide-y divide-border overflow-hidden rounded-md border border-border bg-surface-subtle">
        {details.map((detail) => (
          <li className="break-all px-3 py-2.5" key={detail}>
            {detail}
          </li>
        ))}
      </ul>
      <Notice tone="warning">{deploymentWarning}</Notice>
      {warnings.map((warning) => (
        <Notice contentClassName="break-words" key={warning} tone="danger">
          {warning}
        </Notice>
      ))}
    </div>
  )
}
