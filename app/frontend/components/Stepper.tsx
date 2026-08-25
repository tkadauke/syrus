export type StepperStep = {
  key: string
  label: string
  done: boolean
}

// Generic N-step progress indicator. `active` matches a step's `key`; steps
// before/at the active one are typically marked `done` by the caller.
export function Stepper({ steps, active }: { steps: StepperStep[]; active: string }) {
  return (
    <ol className="flex items-center gap-2 text-xs font-medium">
      {steps.map((step, index) => {
        const current = active === step.key
        const tone = step.done
          ? "bg-green-100 text-green-700 dark:bg-green-950/60 dark:text-green-300"
          : current
            ? "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-300"
            : "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"
        return (
          <li className="flex items-center gap-2" key={step.key}>
            <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 ${tone}`}>
              <span>{step.done ? "✓" : index + 1}</span> {step.label}
            </span>
            {index < steps.length - 1 ? <span aria-hidden="true" className="text-gray-300 dark:text-gray-600">→</span> : null}
          </li>
        )
      })}
    </ol>
  )
}
