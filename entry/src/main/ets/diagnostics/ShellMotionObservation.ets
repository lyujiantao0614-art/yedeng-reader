// Debug/test observation of native decoration completion only. Never drives
// routing, persistence, reader-ready, touch ownership or business success.
export class ShellMotionObservation {
  private serial: number = 0;
  private active: Map<string, number> = new Map<string, number>();
  begin(surface: string): number {
    const serial = ++this.serial; this.active.set(surface, serial); return serial;
  }
  finish(surface: string, serial: number): void {
    if (this.active.get(surface) === serial) this.active.delete(surface);
  }
  pending(): boolean { return this.active.size > 0; }
}
export const shellMotionObservation: ShellMotionObservation = new ShellMotionObservation();
