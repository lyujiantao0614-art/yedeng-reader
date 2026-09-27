import {
  AdaptiveWindowSnapshot,
  DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT
} from './AdaptiveLayoutPolicy';

export type AdaptiveWindowSnapshotHandler = (snapshot: AdaptiveWindowSnapshot) => void;

function snapshotsMatch(first: AdaptiveWindowSnapshot, second: AdaptiveWindowSnapshot): boolean {
  return first.widthVp === second.widthVp && first.heightVp === second.heightVp &&
    first.safeInsets.top === second.safeInsets.top && first.safeInsets.right === second.safeInsets.right &&
    first.safeInsets.bottom === second.safeInsets.bottom && first.safeInsets.left === second.safeInsets.left &&
    first.usableWidthVp === second.usableWidthVp && first.usableHeightVp === second.usableHeightVp &&
    first.sizeClass === second.sizeClass && first.foldOccluded === second.foldOccluded;
}

export class AdaptiveWindowLifecycle {
  private currentSnapshot: AdaptiveWindowSnapshot = DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT;
  private handlers: AdaptiveWindowSnapshotHandler[] = [];

  snapshot(): AdaptiveWindowSnapshot {
    return this.currentSnapshot;
  }

  subscribe(handler: AdaptiveWindowSnapshotHandler): () => void {
    if (!this.handlers.includes(handler)) this.handlers.push(handler);
    handler(this.currentSnapshot);
    return (): void => { this.unsubscribe(handler); };
  }

  unsubscribe(handler: AdaptiveWindowSnapshotHandler): void {
    this.handlers = this.handlers.filter((candidate) => candidate !== handler);
  }

  handleSnapshot(snapshot: AdaptiveWindowSnapshot): void {
    if (snapshotsMatch(this.currentSnapshot, snapshot)) return;
    this.currentSnapshot = snapshot;
    for (const handler of this.handlers.slice()) handler(snapshot);
  }
}

export const adaptiveWindowLifecycle: AdaptiveWindowLifecycle = new AdaptiveWindowLifecycle();
