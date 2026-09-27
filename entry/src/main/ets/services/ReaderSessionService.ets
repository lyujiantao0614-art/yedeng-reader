import { ReadingLocation, ReadingProgress } from '../domain/Models';
import { LibraryRepository } from '../repositories/LibraryRepository';

interface PendingSessionProgress {
  sessionId: number;
  progress: ReadingProgress;
}

export class ReaderSessionService {
  private repository?: LibraryRepository;
  private pending?: PendingSessionProgress;
  private timer: number = -1;
  private activeSessionId: number = 0;
  private activeBookId: string = '';

  initialize(repository: LibraryRepository): void {
    this.repository = repository;
  }

  begin(sessionId: number, bookId: string): void {
    this.cancelTimer();
    this.pending = undefined;
    this.activeSessionId = sessionId;
    this.activeBookId = bookId;
  }

  invalidate(sessionId: number): void {
    if (sessionId !== this.activeSessionId) return;
    this.cancelTimer();
    this.pending = undefined;
    this.activeBookId = '';
  }

  update(sessionId: number, bookId: string, location: ReadingLocation): void {
    if (sessionId !== this.activeSessionId || bookId !== this.activeBookId) return;
    this.pending = {
      sessionId: sessionId,
      progress: { bookId: bookId, location: location, updatedAt: Date.now() }
    };
    this.cancelTimer();
    this.timer = setTimeout((): void => {
      this.flush(sessionId).catch((): void => {});
    }, 900);
  }

  async flush(sessionId?: number): Promise<void> {
    if (sessionId !== undefined && sessionId !== this.activeSessionId) return;
    this.cancelTimer();
    const value = this.pending;
    if (value === undefined || value.sessionId !== this.activeSessionId ||
      value.progress.bookId !== this.activeBookId || this.repository === undefined) return;
    this.pending = undefined;
    await this.repository.saveProgress(value.progress);
  }

  private cancelTimer(): void {
    if (this.timer < 0) return;
    clearTimeout(this.timer);
    this.timer = -1;
  }
}

export const readerSessionService: ReaderSessionService = new ReaderSessionService();
