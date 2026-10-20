export type ReaderSurface = 'none' | 'toc' | 'notes' | 'bookmarks' | 'progress' | 'appearance' | 'dictionary' | 'passage' | 'note-editor' | 'mark-detail';

export type PassageRequestKind = 'none' | 'copy' | 'highlight' | 'note' | 'adjust';

export function shouldDismissTransientSurfaceForLocation(cause: 'layout' | 'navigation'): boolean {
  return cause === 'navigation';
}

export class ReaderSurfaceState {
  private current: ReaderSurface = 'none';

  surface(): ReaderSurface {
    return this.current;
  }

  show(surface: ReaderSurface): void {
    this.current = surface;
  }

  dismiss(): void {
    this.current = 'none';
  }
}
