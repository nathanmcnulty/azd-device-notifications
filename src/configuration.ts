export function boundedNumber(
  name: string,
  raw: string | undefined,
  fallback: number,
  minimum: number,
  maximum: number
): number {
  const value = raw === undefined || raw.trim() === "" ? fallback : Number(raw);
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return value;
}
