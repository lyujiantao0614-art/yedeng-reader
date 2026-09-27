import { ImportCancellation } from '../services/ImportCancellation';
import { Book, LibraryOperationKind, ReadingProgress, ReconciliationReport } from '../domain/Models';
import { LibraryRepository } from '../repositories/LibraryRepository';
import { BookDeletionService } from '../services/BookDeletionService';
import { BookImportService, ImportResult } from '../services/BookImportService';
import { LibraryEntry } from '../services/LibraryQueryService';
import { LibraryReconciliationService } from '../services/LibraryReconciliationService';
import { ManagedBookStore } from '../services/ManagedBookStore';
import { BatchImportCoordinator, BatchImportObserver, BatchImportSnapshot } from './BatchImportCoordinator';
import { TxtEncodingChoice, TxtPreview } from '../domain/TxtEncoding';

interface PendingLibraryOperation {
  operationId: string;
  kind: LibraryOperationKind;
  bookId: string;
  sessionId: number;
}

class LibraryOpenControl extends ImportCancellation {}

export type LibraryRollbackState = 'none' | 'rolled-back' | 'cleanup-pending';

export interface LibraryOpenState {
  status: 'ready' | 'rejected' | 'cancelled';
  message?: string;
  progress?: ReadingProgress;
  epubBytes?: number;
}

export class LibraryApplication {
  private repository: LibraryRepository;
  private importService: BookImportService;
  private deletionService: BookDeletionService;
  private reconciliationService: LibraryReconciliationService;
  private managedStore: ManagedBookStore;
  private pending?: PendingLibraryOperation;
  private openControl?: LibraryOpenControl;
  private batch: BatchImportCoordinator;

  constructor(repository: LibraryRepository, importService: BookImportService,
    deletionService: BookDeletionService, reconciliationService: LibraryReconciliationService,
    managedStore: ManagedBookStore) {
    this.repository = repository;
    this.importService = importService;
    this.deletionService = deletionService;
    this.reconciliationService = reconciliationService;
    this.managedStore = managedStore;
    this.batch = new BatchImportCoordinator(importService);
  }

  async reconcile(): Promise<ReconciliationReport> {
    return this.reconciliationService.reconcile();
  }

  async listEntries(): Promise<LibraryEntry[]> {
    const books = await this.repository.listBooks();
    const entries: LibraryEntry[] = [];
    for (const book of books) {
      const progress = await this.repository.getProgress(book.bookId);
      entries.push({ book: book, percentage: progress?.location.percentage ?? 0 });
    }
    return entries;
  }

  async import(uri?: string): Promise<ImportResult> {
    if (this.batch.isRunning()) return { status: 'io_error', message: '批量导入正在进行，请稍候。' };
    const result = await this.importService.import(uri);
    this.rememberPrepared(result);
    return result;
  }

  async repair(book: Book, uri?: string): Promise<ImportResult> {
    if (this.batch.isRunning()) return { status: 'io_error', message: '批量导入正在进行，请稍候。' };
    const result = await this.importService.repair(book, uri);
    this.rememberPrepared(result);
    return result;
  }

  private rememberPrepared(result: ImportResult): void {
    if (result.book === undefined || result.operationId === undefined || result.operationKind === undefined ||
      (result.status !== 'prepared-new' && result.status !== 'prepared-repair')) return;
    this.pending = {
      operationId: result.operationId,
      kind: result.operationKind,
      bookId: result.book.bookId,
      sessionId: 0
    };
  }

  hasPreparedBook(bookId: string): boolean {
    return this.pending?.bookId === bookId;
  }

  bindPreparedSession(bookId: string, sessionId: number): void {
    if (this.pending?.bookId === bookId) this.pending.sessionId = sessionId;
  }

  async commitPrepared(sessionId: number, book: Book): Promise<boolean> {
    const pending = this.pending;
    if (pending === undefined || pending.sessionId !== sessionId || pending.bookId !== book.bookId) return false;
    await this.importService.commitPrepared(pending.operationId, pending.kind, book);
    this.pending = undefined;
    return true;
  }

  async rollbackPrepared(sessionId: number): Promise<LibraryRollbackState> {
    const pending = this.pending;
    if (pending === undefined || pending.sessionId !== sessionId) return 'none';
    try {
      return await this.importService.rollbackPrepared(pending.operationId, pending.bookId) ? 'rolled-back' : 'cleanup-pending';
    } catch (_) {
      return 'cleanup-pending';
    } finally {
      this.pending = undefined;
    }
  }

  cancelOpenCheck(): boolean {
    if (this.openControl === undefined) return false;
    this.openControl.cancelled = true;
    return true;
  }

  async importBundled(uri: string): Promise<ImportResult> {
    if (this.batch.isRunning()) return { status: 'io_error' };
    const result = await this.importService.import(uri);
    if ((result.status === 'prepared-new' || result.status === 'prepared-repair') && result.operationId !== undefined &&
      result.operationKind !== undefined && result.book !== undefined) {
      await this.importService.commitPrepared(result.operationId, result.operationKind, result.book);
    }
    return result;
  }

  batchState(): BatchImportSnapshot { return this.batch.snapshot(); }
  addBatchSelection(uris: string[]): BatchImportSnapshot { return this.batch.addSelection(uris); }
  checkBatchTextEncoding(): Promise<BatchImportSnapshot> { return this.batch.checkTextEncoding(); }
  previewBatchText(id: number, encoding: TxtEncodingChoice): Promise<TxtPreview> {
    return this.batch.previewText(id, encoding);
  }
  setBatchTextEncoding(id: number, encoding: TxtEncodingChoice): BatchImportSnapshot {
    return this.batch.setTextEncoding(id, encoding);
  }
  removeBatchItem(id: number): BatchImportSnapshot { return this.batch.remove(id); }
  cancelBatchReview(): BatchImportSnapshot { return this.batch.cancelReview(); }
  resetBatchResults(): BatchImportSnapshot { return this.batch.resetResults(); }
  runBatch(observer: BatchImportObserver): Promise<BatchImportSnapshot> { return this.batch.confirm(observer); }
  cancelBatch(): boolean { return this.batch.cancel(); }
  setBatchForeground(foreground: boolean): void { this.batch.setForeground(foreground); }
  isBatchRunning(): boolean { return this.batch.isRunning(); }

  async openState(book: Book): Promise<LibraryOpenState> {
    if (this.openControl !== undefined) return { status: 'rejected', message: '正在检查书籍，请稍候。' };
    const control = new LibraryOpenControl();
    this.openControl = control;
    try {
      // A prepared import/repair was inspected in this live operation already.
      if (!this.hasPreparedBook(book.bookId)) {
        const validation = await this.importService.validateManaged(book.bookId, control);
        if (validation.status !== 'valid' && validation.status !== 'cancelled') return { status: 'rejected', message: validation.message };
        if (control.cancelled || validation.status === 'cancelled') return { status: 'cancelled' };
      }
      if (control.cancelled) return { status: 'cancelled' };
      const progress = await this.repository.getProgress(book.bookId);
      let epubBytes: number | undefined;
      try { epubBytes = await this.managedStore.bookFileSize(book.bookId); } catch (_) {}
      return control.cancelled ? { status: 'cancelled' } : { status: 'ready', progress: progress, epubBytes: epubBytes };
    } finally {
      if (this.openControl === control) this.openControl = undefined;
    }
  }

  async markOpened(bookId: string, openedAt: number): Promise<void> {
    await this.repository.markOpened(bookId, openedAt);
  }

  async renameBook(bookId: string, title: string, author: string): Promise<Book> {
    if (this.batch.isRunning()) throw new Error('Batch import owns library storage');
    const normalizedTitle = title.trim();
    const normalizedAuthor = author.trim();
    if (normalizedTitle.length === 0 || normalizedTitle.length > 120 || normalizedAuthor.length > 120 ||
      /[\u0000-\u001F\u007F]/.test(normalizedTitle + normalizedAuthor)) {
      throw new Error('Invalid book metadata');
    }
    const book = await this.repository.getBook(bookId);
    if (book === undefined) throw new Error('Book not found');
    await this.repository.updateBookMetadata(bookId, normalizedTitle,
      normalizedAuthor.length > 0 ? normalizedAuthor : undefined);
    return {
      bookId: book.bookId, fileHash: book.fileHash, title: normalizedTitle,
      author: normalizedAuthor.length > 0 ? normalizedAuthor : undefined,
      epubRelativePath: book.epubRelativePath, coverRelativePath: book.coverRelativePath,
      importedAt: book.importedAt, lastOpenedAt: book.lastOpenedAt, sourceState: book.sourceState
    };
  }

  async bookSize(bookId: string): Promise<number | undefined> {
    try { return await this.managedStore.bookFileSize(bookId); }
    catch (_) { return undefined; }
  }

  async delete(book: Book): Promise<void> {
    if (this.batch.isRunning()) throw new Error('Batch import owns library storage');
    await this.deletionService.delete(book);
  }

  async cleanupQuarantinedOrphans(): Promise<number> {
    if (this.batch.isRunning()) return 0;
    return this.reconciliationService.cleanupQuarantinedOrphans();
  }
}
