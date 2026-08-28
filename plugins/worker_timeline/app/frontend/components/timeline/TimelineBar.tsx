// A single interactive time-scaled bar, shared by the macro (Workflow span)
// and micro (Run span) chart views. Hover always shows a tooltip; `onClick`
// is optional (Workflow spans navigate to the waterfall drill-down, Run
// spans within that drill-down currently don't need a click target).
export function TimelineBar({
  x,
  width,
  fill,
  ariaLabel,
  onClick,
  onHover
}: {
  x: number
  width: number
  fill: string
  ariaLabel: string
  onClick?: () => void
  onHover: (position: { x: number; y: number } | null) => void
}) {
  return (
    <rect
      aria-label={ariaLabel}
      fill={fill}
      height="20"
      onClick={onClick}
      onKeyDown={onClick ? (event) => {
        if (event.key !== "Enter" && event.key !== " ") return
        event.preventDefault()
        onClick()
      } : undefined}
      onMouseEnter={(event) => onHover({ x: event.clientX, y: event.clientY })}
      onMouseLeave={() => onHover(null)}
      onMouseMove={(event) => onHover({ x: event.clientX, y: event.clientY })}
      rx="3"
      role={onClick ? "button" : "img"}
      style={onClick ? { cursor: "pointer" } : undefined}
      tabIndex={onClick ? 0 : -1}
      width={Math.max(2, width)}
      x={x}
      y="6"
    />
  )
}
