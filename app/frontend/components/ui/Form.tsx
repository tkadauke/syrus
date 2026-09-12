import { createContext, forwardRef, useContext, useEffect, useId, useMemo, useState } from "react"
import type { ComponentPropsWithoutRef, HTMLAttributes, LabelHTMLAttributes, ReactNode } from "react"
import { Checkbox, type CheckboxProps } from "../Checkbox"
import { Input, type InputProps } from "../Input"
import { Select, type SelectProps } from "../Select"
import { Textarea, type TextareaProps } from "../Textarea"
import { Toggle, type ToggleProps } from "../Toggle"
import { classes } from "./classes"

export type FormFieldLayout = "stacked" | "inline"

export interface FormFieldProps extends HTMLAttributes<HTMLDivElement> {
  controlId?: string
  disabled?: boolean
  error?: ReactNode
  invalid?: boolean
  layout?: FormFieldLayout
}

type FormFieldContextValue = {
  controlId: string
  disabled: boolean
  error: ReactNode
  errorTextId: string
  helpTextId: string
  invalid: boolean
  layout: FormFieldLayout
  mountedErrorTextId: string | null
  mountedHelpTextId: string | null
  setMountedErrorTextId: (id: string | null) => void
  setMountedHelpTextId: (id: string | null) => void
}

const FormFieldContext = createContext<FormFieldContextValue | null>(null)

const FIELD_LAYOUT_CLASSES: Record<FormFieldLayout, string> = {
  stacked: "space-y-1.5",
  inline: "grid gap-2 sm:grid-cols-[minmax(10rem,14rem)_minmax(0,1fr)] sm:items-start"
}

function useFormFieldContext(component: string) {
  const context = useContext(FormFieldContext)
  if (!context) throw new Error(`${component} must be rendered inside Form.Field`)
  return context
}

function Field({
  children,
  className = "",
  controlId,
  disabled = false,
  error,
  invalid = false,
  layout = "stacked",
  ...props
}: FormFieldProps) {
  const reactId = useId()
  const resolvedControlId = controlId ?? `form-field-${reactId}`
  const [mountedHelpTextId, setMountedHelpTextId] = useState<string | null>(null)
  const [mountedErrorTextId, setMountedErrorTextId] = useState<string | null>(null)
  const resolvedInvalid = invalid || Boolean(error)
  const value = useMemo<FormFieldContextValue>(() => ({
    controlId: resolvedControlId,
    disabled,
    error,
    errorTextId: `${resolvedControlId}-error`,
    helpTextId: `${resolvedControlId}-help`,
    invalid: resolvedInvalid,
    layout,
    mountedErrorTextId,
    mountedHelpTextId,
    setMountedErrorTextId,
    setMountedHelpTextId
  }), [disabled, error, layout, mountedErrorTextId, mountedHelpTextId, resolvedControlId, resolvedInvalid])

  return (
    <FormFieldContext.Provider value={value}>
      <div
        className={classes(
          FIELD_LAYOUT_CLASSES[layout],
          disabled && "opacity-70",
          resolvedInvalid && "data-[invalid=true]:text-danger-text",
          className
        )}
        data-disabled={disabled || undefined}
        data-invalid={resolvedInvalid || undefined}
        {...props}
      >
        {children}
      </div>
    </FormFieldContext.Provider>
  )
}

export interface FormLabelProps extends LabelHTMLAttributes<HTMLLabelElement> {
  required?: boolean
}

function Label({ children, className = "", htmlFor, required = false, ...props }: FormLabelProps) {
  const context = useFormFieldContext("Form.Label")

  return (
    <label
      className={classes("block text-sm font-medium leading-5 text-text-primary", context.disabled && "cursor-not-allowed text-text-muted", className)}
      htmlFor={htmlFor ?? context.controlId}
      {...props}
    >
      {children}
      {required ? <span aria-hidden="true" className="ml-1 text-danger-text">*</span> : null}
    </label>
  )
}

export type FormTextProps = HTMLAttributes<HTMLParagraphElement>

function HelpText({ children, className = "", id, ...props }: FormTextProps) {
  const context = useFormFieldContext("Form.HelpText")
  const resolvedId = id ?? context.helpTextId

  useEffect(() => {
    context.setMountedHelpTextId(resolvedId)
    return () => context.setMountedHelpTextId(null)
  }, [context.setMountedHelpTextId, resolvedId])

  return (
    <p className={classes("text-xs leading-4 text-text-muted", className)} id={resolvedId} {...props}>
      {children}
    </p>
  )
}

function ErrorText({ children, className = "", id, ...props }: FormTextProps) {
  const context = useFormFieldContext("Form.ErrorText")
  const content = children ?? context.error
  const resolvedId = id ?? context.errorTextId

  useEffect(() => {
    context.setMountedErrorTextId(content ? resolvedId : null)
    return () => context.setMountedErrorTextId(null)
  }, [context.setMountedErrorTextId, content, resolvedId])

  if (!content) return null

  return (
    <p className={classes("text-xs font-medium leading-4 text-danger-text", className)} id={resolvedId} role="alert" {...props}>
      {content}
    </p>
  )
}

export interface FormActionsProps extends HTMLAttributes<HTMLDivElement> {
  align?: "start" | "end" | "between"
}

const ACTION_ALIGN_CLASSES: Record<NonNullable<FormActionsProps["align"]>, string> = {
  start: "justify-start",
  end: "justify-end",
  between: "justify-between"
}

function Actions({ align = "end", className = "", ...props }: FormActionsProps) {
  return <div className={classes("flex flex-wrap items-center gap-2 pt-[var(--space-section-compact)]", ACTION_ALIGN_CLASSES[align], className)} {...props} />
}

function describedBy(context: FormFieldContextValue, explicit: string | undefined) {
  const ids = [
    explicit,
    context.mountedHelpTextId,
    context.mountedErrorTextId
  ].filter(Boolean)

  return ids.length > 0 ? ids.join(" ") : undefined
}

function controlProps<T extends { "aria-describedby"?: string; disabled?: boolean; id?: string; invalid?: boolean }>(
  props: T,
  context: FormFieldContextValue
) {
  return {
    ...props,
    "aria-describedby": describedBy(context, props["aria-describedby"]),
    disabled: props.disabled ?? context.disabled,
    id: props.id ?? context.controlId,
    invalid: props.invalid ?? context.invalid
  }
}

const FormInput = forwardRef<HTMLInputElement, InputProps>(function FormInput(props, ref) {
  const context = useFormFieldContext("Form.Input")
  return <Input ref={ref} {...controlProps(props, context)} />
})

const FormSelect = forwardRef<HTMLSelectElement, SelectProps>(function FormSelect(props, ref) {
  const context = useFormFieldContext("Form.Select")
  return <Select ref={ref} {...controlProps(props, context)} />
})

const FormTextarea = forwardRef<HTMLTextAreaElement, TextareaProps>(function FormTextarea(props, ref) {
  const context = useFormFieldContext("Form.Textarea")
  return <Textarea ref={ref} {...controlProps(props, context)} />
})

const FormCheckbox = forwardRef<HTMLInputElement, CheckboxProps>(function FormCheckbox(props, ref) {
  const context = useFormFieldContext("Form.Checkbox")
  return <Checkbox ref={ref} {...controlProps(props, context)} />
})

type FormToggleProps = Omit<ComponentPropsWithoutRef<typeof Toggle>, "invalid"> & {
  invalid?: boolean
}

const FormToggle = forwardRef<HTMLButtonElement, FormToggleProps>(function FormToggle(props, ref) {
  const context = useFormFieldContext("Form.Toggle")
  const { invalid: _invalid, ...toggleProps } = controlProps(props, context)
  return <Toggle ref={ref} {...toggleProps} />
})

export const Form = {
  Actions,
  Checkbox: FormCheckbox,
  ErrorText,
  Field,
  HelpText,
  Input: FormInput,
  Label,
  Select: FormSelect,
  Textarea: FormTextarea,
  Toggle: FormToggle
}
