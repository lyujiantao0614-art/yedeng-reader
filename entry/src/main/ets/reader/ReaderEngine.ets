import { Book, BookmarkPoint, Chapter, ReaderColumnMode, ReaderSettings, ReadingLocation } from '../domain/Models';
import { PassageSelectionCandidate, ReadingRangeCandidate, ReadingSelectionContext } from './ReadingSelectionModels';
import { ReaderSelectionGeometry, ReaderSelectionRect } from './ReaderSelectionModels';

export { ReaderSelectionGeometry, ReaderSelectionRect } from './ReaderSelectionModels';

export type ReaderInternalLinkKind = 'internal' | 'footnote';

export type ReaderLocationCause = 'layout' | 'navigation';

export interface ReaderLinkState {
  canReturn: boolean;
  kind?: ReaderInternalLinkKind;
}

export interface ReaderExternalLinkRequest {
  requestId: number;
  url: string;
}

export interface ReaderWordSelection {
  engine: string;
  selectionToken: string;
  characterCount: number;
  surfaceForm: string;
  locator: string;
  geometry?: ReaderSelectionGeometry;
  // Retained while ReaderPage migrates to fragment-aware placement.
  rect?: ReaderSelectionRect;
}

// Transient V4 renderer input. Durable records require ADR 0018's versioned anchor contract.
export interface ReaderTextMark extends ReadingRangeCandidate {
  markId: string;
  bookId: string;
  anchorVersion: number;
  engine: string;
  kind?: 'highlight' | 'note';
  revision?: number;
  highlightActive?: boolean;
  noteAnchors?: ReaderNoteAnchor[];
  highlightAnchors?: ReadingRangeCandidate[];
}

export interface ReaderNoteAnchor extends ReadingRangeCandidate {
  noteId: string;
  revision: number;
  provenance: string;
}

export interface ReaderTextMarkResolution {
  revision?: number;
  status: 'verified' | 'recovered' | 'orphaned';
  cfi?: string;
  reason?: 'missing' | 'ambiguous' | 'unavailable';
}

export type ReaderFatalErrorCategory = 'reader-session' | 'shell-page' | 'reader-command' |
  'bridge-initialization' | 'bridge-page' | 'bridge-protocol' | 'reader-engine' |
  'book-response' | 'navigation';

export interface ReaderEngineCallbacks {
  onSelectionAction?: (sessionId: number, action: 'copy' | 'note' | 'translate', selectionToken: string,
    selectedText: string, locator: string, complete?: () => void) => void;
  onSelectionMarkContext?: (sessionId: number, context: ReadingSelectionContext) => void;
  onNoteAnchorResolution?: (sessionId: number,noteId: string,revision: number,resolution: ReaderTextMarkResolution) => void;
  onFirstReadable?: (sessionId: number) => void;
  onPreparationState?: (sessionId: number, queued: number, active: number) => void;
  onContactState?: (sessionId: number, state: 'active' | 'cancelled') => void;
  onReady: (sessionId: number) => void;
  onTableOfContents: (sessionId: number, chapters: Chapter[]) => void;
  onLocation: (sessionId: number, location: ReadingLocation, cause: ReaderLocationCause) => void;
  onWordSelection: (sessionId: number, selection: ReaderWordSelection) => void;
  onPassageSelection: (sessionId: number, selection: PassageSelectionCandidate) => void;
  onSelectionAdjusting: (sessionId: number) => void;
  onSelectionContext: (sessionId: number, context: ReadingSelectionContext) => void;
  onSelectionContextRejected: (sessionId: number, selectionToken: string, reason: string) => void;
  onSelectionRejected: (sessionId: number, reason: string, characterCount?: number) => void;
  onSelectionCleared: (sessionId: number, cause?: 'cancel' | 'presentation') => void;
  onSelectionGeometryChanged: (sessionId: number, selectionToken: string,
    geometry: ReaderSelectionGeometry) => void;
  onControlsToggle: (sessionId: number) => void;
  onLinkState: (sessionId: number, state: ReaderLinkState) => void;
  onExternalLinkRequest: (sessionId: number, request: ReaderExternalLinkRequest) => void;
  onBackRequested: (sessionId: number) => void;
  onError: (sessionId: number, category: ReaderFatalErrorCategory) => void;
  onBookmarkJumpResult?: (sessionId: number, bookmarkId: string, success: boolean) => void;
  onPageExcerpt?: (sessionId: number, excerpt: string) => void;
  onTextMarkResult?: (sessionId: number, markId: string, action: 'preview' | 'jump', success: boolean) => void;
  onTextMarkResolution?: (sessionId: number, markId: string, resolution: ReaderTextMarkResolution) => void;
  onTextMarkTap?: (sessionId: number, markId: string, rect: ReaderSelectionRect) => void;
}

export interface NextPageReaderCommand { type: 'nextPage'; }
export interface PreviousPageReaderCommand { type: 'previousPage'; }
export interface NextChapterReaderCommand { type: 'nextChapter'; }
export interface PreviousChapterReaderCommand { type: 'previousChapter'; }
export interface GoToChapterReaderCommand { type: 'goToChapter'; href: string; }
export interface ApplySettingsReaderCommand { type: 'applySettings'; settings: ReaderSettings; }
export interface ApplyColumnModeReaderCommand { type: 'applyColumnMode'; mode: ReaderColumnMode; }
export interface ClearSelectionReaderCommand { type: 'clearSelection'; }
export interface FocusContentReaderCommand { type: 'focusContent'; }
export interface ReturnFromInternalLinkReaderCommand { type: 'returnFromInternalLink'; }
export interface RequestSelectionContextReaderCommand {
  type: 'requestSelectionContext';
  selectionToken: string;
  sessionId: number;
  marks?: ReaderTextMark[];
  excludeMarkId?: string;
}
export interface RequestLocationReaderCommand { type: 'requestLocation'; }
export interface RequestPageExcerptReaderCommand { type: 'requestPageExcerpt'; sessionId: number; }
export interface PreviewTextMarkReaderCommand { type: 'previewTextMark'; mark: ReaderTextMark; sessionId: number; }
export interface GoToTextMarkReaderCommand { type: 'goToTextMark'; mark: ReaderTextMark; sessionId: number; }
export interface RemoveTextMarkReaderCommand { type: 'removeTextMark'; markId: string; sessionId: number; }
export interface GoToBookmarkReaderCommand { type: 'goToBookmark'; point: BookmarkPoint; sessionId: number; }
export interface OpenBookReaderCommand {
  type: 'openBook';
  book: Book;
  location?: ReadingLocation;
  settings: ReaderSettings;
  sessionId: number;
}

export type ReaderCommand = NextPageReaderCommand | PreviousPageReaderCommand |
  NextChapterReaderCommand | PreviousChapterReaderCommand | GoToChapterReaderCommand |
  ApplySettingsReaderCommand | ApplyColumnModeReaderCommand | ClearSelectionReaderCommand |
  FocusContentReaderCommand |
  ReturnFromInternalLinkReaderCommand | RequestSelectionContextReaderCommand | RequestLocationReaderCommand |
  OpenBookReaderCommand | GoToBookmarkReaderCommand | RequestPageExcerptReaderCommand |
  PreviewTextMarkReaderCommand | GoToTextMarkReaderCommand | RemoveTextMarkReaderCommand;

export class ReaderEngineController {
  private dispatcher?: (command: ReaderCommand) => void;

  bind(dispatcher: (command: ReaderCommand) => void): void {
    this.dispatcher = dispatcher;
  }

  unbind(): void {
    this.dispatcher = undefined;
  }

  nextPage(): void { this.send({ type: 'nextPage' }); }
  previousPage(): void { this.send({ type: 'previousPage' }); }
  nextChapter(): void { this.send({ type: 'nextChapter' }); }
  previousChapter(): void { this.send({ type: 'previousChapter' }); }
  goToChapter(href: string): void { this.send({ type: 'goToChapter', href: href }); }
  applySettings(settings: ReaderSettings): void { this.send({ type: 'applySettings', settings: settings }); }
  applyColumnMode(mode: ReaderColumnMode): void { this.send({ type: 'applyColumnMode', mode: mode }); }
  clearSelection(): void { this.send({ type: 'clearSelection' }); }
  focusContent(): void { this.send({ type: 'focusContent' }); }
  returnFromInternalLink(): void { this.send({ type: 'returnFromInternalLink' }); }
  requestSelectionContext(selectionToken: string, sessionId: number,
    marks?: ReaderTextMark[], excludeMarkId?: string): void {
    this.send({ type: 'requestSelectionContext', selectionToken: selectionToken, sessionId: sessionId,
      marks: marks, excludeMarkId: excludeMarkId });
  }
  requestLocation(): void { this.send({ type: 'requestLocation' }); }
  requestPageExcerpt(sessionId: number): void {
    this.send({ type: 'requestPageExcerpt', sessionId: sessionId });
  }
  previewTextMark(mark: ReaderTextMark, sessionId: number): void {
    this.send({ type: 'previewTextMark', mark: mark, sessionId: sessionId });
  }
  goToTextMark(mark: ReaderTextMark, sessionId: number): void {
    this.send({ type: 'goToTextMark', mark: mark, sessionId: sessionId });
  }
  removeTextMark(markId: string, sessionId: number): void {
    this.send({ type: 'removeTextMark', markId: markId, sessionId: sessionId });
  }
  goToBookmark(point: BookmarkPoint, sessionId: number): void {
    this.send({ type: 'goToBookmark', point: point, sessionId: sessionId });
  }
  openBook(book: Book, location: ReadingLocation | undefined, settings: ReaderSettings, sessionId: number): void {
    this.send({ type: 'openBook', book: book, location: location, settings: settings, sessionId: sessionId });
  }

  private send(command: ReaderCommand): void {
    if (this.dispatcher !== undefined) {
      this.dispatcher(command);
    }
  }
}
