// ArkUI APIs available since API10; no new runtime dependency on API26.
// Unknown system motion preference keeps the ordinary interaction, as before.
export function nonReadingPageTransition(reduced: boolean | undefined): TransitionEffect {
  return reduced === true ? TransitionEffect.IDENTITY :
    TransitionEffect.translate({ x: 16 }).combine(TransitionEffect.OPACITY);
}

export function readingEntryClickEffect(reduced: boolean | undefined): ClickEffect | null {
  return reduced === true ? null : { level: ClickEffectLevel.LIGHT, scale: 0.985 };
}
