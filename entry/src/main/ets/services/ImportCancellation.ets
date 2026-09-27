import { InflateControl } from './BoundedInflater';

// A live import/open operation owns this token. No timer or persisted state.
export class ImportCancellation implements InflateControl {
  private value: boolean = false;
  private listeners: Array<() => void> = [];
  get cancelled(): boolean { return this.value; }
  set cancelled(next: boolean) {
    if (this.value === next) return;
    this.value = next;
    if (next) for (const listener of this.listeners.slice()) {
      try { listener(); } catch (_) {}
    }
  }
  isCancelled(): boolean { return this.value; }
  onCancel(listener: () => void): () => void {
    this.listeners.push(listener);
    if (this.value) listener();
    return (): void => { this.listeners = this.listeners.filter((entry: () => void): boolean => entry !== listener); };
  }
}
