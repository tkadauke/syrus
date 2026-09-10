import type { ComponentPropsWithoutRef, ElementType, ReactNode } from "react"
import { classes } from "./classes"

export type TextVariant = "body" | "muted" | "caption" | "label" | "mono" | "heading-sm" | "heading-md"
export type TextTone = "default" | "muted" | "subtle" | "danger" | "success" | "warning" | "info" | "neutral"

type TextOwnProps<T extends ElementType> = {
  as?: T
  children?: ReactNode
  className?: string
  muted?: boolean
  tone?: TextTone
  variant?: TextVariant
}

export type TextProps<T extends ElementType = "p"> = TextOwnProps<T> &
  Omit<ComponentPropsWithoutRef<T>, keyof TextOwnProps<T>>

const TEXT_VARIANT_CLASSES: Record<TextVariant, string> = {
  body: "text-sm leading-5",
  muted: "text-sm leading-5",
  caption: "text-xs leading-4",
  label: "text-xs font-medium uppercase leading-4 tracking-wide",
  mono: "font-mono text-sm leading-5",
  "heading-sm": "text-sm font-semibold leading-5",
  "heading-md": "text-base font-semibold leading-6"
}

const TEXT_TONE_CLASSES: Record<TextTone, string> = {
  default: "text-text-primary",
  muted: "text-text-muted",
  subtle: "text-text-subtle",
  danger: "text-danger-text",
  success: "text-success-text",
  warning: "text-warning-text",
  info: "text-info-text",
  neutral: "text-neutral-text"
}

export function textClasses({ variant = "body", tone = "default", muted = false, className = "" }: Pick<TextOwnProps<ElementType>, "variant" | "tone" | "muted" | "className"> = {}) {
  const resolvedVariant = muted && variant === "body" ? "muted" : variant
  const resolvedTone = muted ? "muted" : tone
  return classes(TEXT_VARIANT_CLASSES[resolvedVariant], TEXT_TONE_CLASSES[resolvedTone], className)
}

export function Text<T extends ElementType = "p">({
  as,
  children,
  className = "",
  muted = false,
  tone = "default",
  variant = "body",
  ...props
}: TextProps<T>) {
  const Tag = as ?? "p"
  return (
    <Tag className={textClasses({ className, muted, tone, variant })} {...props}>
      {children}
    </Tag>
  )
}
