import { type InputHTMLAttributes, type SelectHTMLAttributes } from 'react';

interface FormFieldBaseProps {
  label: string;
  error?: string;
  required?: boolean;
  hint?: string;
}

type FormInputProps = FormFieldBaseProps & InputHTMLAttributes<HTMLInputElement>;

export function FormInput({ label, error, required, hint, className = '', ...props }: FormInputProps) {
  return (
    <div className="flex flex-col gap-1">
      <label className="text-[10px] uppercase text-ide-textDim font-semibold">
        {label}
        {required && <span className="text-red-400 ml-1">*</span>}
      </label>
      <input
        className={`bg-ide-bg border rounded px-2 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-ide-accent/50 ${
          error ? 'border-red-500' : 'border-ide-border'
        } ${className}`}
        {...props}
      />
      {error && <span className="text-[10px] text-red-400">{error}</span>}
      {hint && !error && <span className="text-[10px] text-ide-textDim">{hint}</span>}
    </div>
  );
}

interface FormSelectProps extends FormFieldBaseProps, SelectHTMLAttributes<HTMLSelectElement> {
  options: Array<{ value: string; label: string; disabled?: boolean }>;
  placeholder?: string;
}

export function FormSelect({
  label,
  error,
  required,
  hint,
  options,
  placeholder,
  className = '',
  ...props
}: FormSelectProps) {
  return (
    <div className="flex flex-col gap-1">
      <label className="text-[10px] uppercase text-ide-textDim font-semibold">
        {label}
        {required && <span className="text-red-400 ml-1">*</span>}
      </label>
      <select
        className={`bg-ide-bg border rounded px-2 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-ide-accent/50 ${
          error ? 'border-red-500' : 'border-ide-border'
        } ${className}`}
        {...props}
      >
        {placeholder && <option value="">{placeholder}</option>}
        {options.map((opt) => (
          <option key={opt.value} value={opt.value} disabled={opt.disabled}>
            {opt.label}
          </option>
        ))}
      </select>
      {error && <span className="text-[10px] text-red-400">{error}</span>}
      {hint && !error && <span className="text-[10px] text-ide-textDim">{hint}</span>}
    </div>
  );
}

interface FormCheckboxProps extends FormFieldBaseProps {
  checked: boolean;
  onChange: (checked: boolean) => void;
}

export function FormCheckbox({ label, error, hint, checked, onChange }: FormCheckboxProps) {
  return (
    <div className="flex flex-col gap-1">
      <label className="flex items-center gap-2 cursor-pointer">
        <input
          type="checkbox"
          checked={checked}
          onChange={(e) => onChange(e.target.checked)}
          className="w-4 h-4 rounded border-ide-border bg-ide-bg text-ide-accent focus:ring-ide-accent/50"
        />
        <span className="text-xs text-ide-text">{label}</span>
      </label>
      {error && <span className="text-[10px] text-red-400">{error}</span>}
      {hint && !error && <span className="text-[10px] text-ide-textDim">{hint}</span>}
    </div>
  );
}

interface FormSpinbuttonProps extends FormFieldBaseProps {
  value: number;
  onChange: (value: number) => void;
  min?: number;
  max?: number;
  step?: number;
  unit?: string;
}

export function FormSpinbutton({
  label,
  error,
  required,
  hint,
  value,
  onChange,
  min,
  max,
  step = 1,
  unit,
}: FormSpinbuttonProps) {
  return (
    <div className="flex flex-col gap-1">
      <label className="text-[10px] uppercase text-ide-textDim font-semibold">
        {label}
        {required && <span className="text-red-400 ml-1">*</span>}
      </label>
      <div className="flex items-center gap-2">
        <input
          type="number"
          value={value}
          onChange={(e) => onChange(Number(e.target.value))}
          min={min}
          max={max}
          step={step}
          className={`bg-ide-bg border rounded px-2 py-1.5 text-xs w-20 focus:outline-none focus:ring-2 focus:ring-ide-accent/50 ${
            error ? 'border-red-500' : 'border-ide-border'
          }`}
        />
        {unit && <span className="text-xs text-ide-textDim">{unit}</span>}
      </div>
      {error && <span className="text-[10px] text-red-400">{error}</span>}
      {hint && !error && <span className="text-[10px] text-ide-textDim">{hint}</span>}
    </div>
  );
}
