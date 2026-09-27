import { SystemColorMode } from '../domain/AppearancePolicy';

export type SystemColorModeHandler = (mode: SystemColorMode) => void;

export class SystemColorModeLifecycle {
  private currentMode: SystemColorMode = 'light';
  private handlers: SystemColorModeHandler[] = [];

  mode(): SystemColorMode {
    return this.currentMode;
  }

  subscribe(handler: SystemColorModeHandler): () => void {
    if (!this.handlers.includes(handler)) this.handlers.push(handler);
    handler(this.currentMode);
    return (): void => { this.unsubscribe(handler); };
  }

  unsubscribe(handler: SystemColorModeHandler): void {
    this.handlers = this.handlers.filter((candidate) => candidate !== handler);
  }

  handleMode(mode: SystemColorMode): void {
    if (mode === this.currentMode) return;
    this.currentMode = mode;
    for (const handler of this.handlers.slice()) handler(mode);
  }
}

export const systemColorModeLifecycle: SystemColorModeLifecycle = new SystemColorModeLifecycle();
