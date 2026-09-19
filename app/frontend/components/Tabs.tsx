import type { ReactNode } from "react"
import { Link } from "react-router-dom"
import { CloseIcon } from "./CloseIcon"

type TabKey = string | number

const TAB_CLOSE_BUTTON_CLASS = [
  "rounded p-0.5 opacity-0 transition",
  "text-text-muted hover:bg-surface-raised hover:text-text-primary",
  "focus:opacity-100 group-hover:opacity-100"
].join(" ")

export type UnderlineTabItem<Key extends TabKey = string> = {
  key: Key
  label: ReactNode
  to?: string
  title?: string
  badge?: ReactNode
  disabled?: boolean
  closeLabel?: string
  onClose?: () => void
  tabClassName?: string
  labelClassName?: string
}

const DEFAULT_ACTIVE_TAB_CLASS = "border-brand text-brand dark:border-brand dark:text-brand-emphasis"
const DEFAULT_INACTIVE_TAB_CLASS = "border-transparent text-gray-600 hover:border-gray-300 hover:text-gray-900 dark:text-gray-400 dark:hover:border-gray-600 dark:hover:text-gray-100"

export function underlineTabClass(active: boolean, className = "", activeClassName = DEFAULT_ACTIVE_TAB_CLASS, inactiveClassName = DEFAULT_INACTIVE_TAB_CLASS) {
  return [
    "shrink-0 border-b-2 font-medium",
    active ? activeClassName : inactiveClassName,
    className
  ].filter(Boolean).join(" ")
}

export function UnderlineTabs<Key extends TabKey>({
  activeKey,
  activeClassName,
  ariaLabel,
  as: Element = "nav",
  className = "flex border-b border-gray-200 dark:border-gray-700",
  inactiveClassName,
  itemClassName = "px-4 py-2 text-sm",
  items,
  onSelect
}: {
  activeKey: Key | null
  activeClassName?: string
  ariaLabel: string
  as?: "nav" | "div"
  className?: string
  inactiveClassName?: string
  itemClassName?: string
  items: UnderlineTabItem<Key>[]
  onSelect?: (key: Key) => void
}) {
  return (
    <Element aria-label={ariaLabel} className={className}>
      {items.map((item) => {
        const active = item.key === activeKey
        const tabClassName = underlineTabClass(active, [itemClassName, item.tabClassName].filter(Boolean).join(" "), activeClassName, inactiveClassName)
        const content = (
          <>
            <span className={item.labelClassName}>{item.label}</span>
            {item.badge}
          </>
        )

        if (item.onClose) {
          return (
            <span className={`group flex items-center gap-1 ${tabClassName}`} key={String(item.key)}>
              <button className={item.labelClassName} onClick={() => onSelect?.(item.key)} title={item.title} type="button">
                {item.label}
              </button>
              <button
                aria-label={item.closeLabel}
                className={TAB_CLOSE_BUTTON_CLASS}
                disabled={item.disabled}
                onClick={(event) => {
                  event.stopPropagation()
                  item.onClose?.()
                }}
                type="button"
              >
                <CloseIcon className="h-3 w-3" />
              </button>
            </span>
          )
        }

        if (item.to) {
          return (
            <Link className={tabClassName} key={String(item.key)} title={item.title} to={item.to}>
              {content}
            </Link>
          )
        }

        return (
          <button
            className={tabClassName}
            disabled={item.disabled}
            key={String(item.key)}
            onClick={() => onSelect?.(item.key)}
            title={item.title}
            type="button"
          >
            {content}
          </button>
        )
      })}
    </Element>
  )
}
