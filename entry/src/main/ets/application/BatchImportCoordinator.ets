import { Book } from '../domain/Models';
import { ROOT_FOLDER } from '../domain/LibraryOrganization';
import { BookImportService, ImportResult } from '../services/BookImportService';
import { ImportCancellation } from '../services/ImportCancellation';
import { VISIBLE_IMPORT_BATCH_LIMIT } from '../services/ProductionImportPolicy';
import { TxtEncodingChoice, TxtPreview } from '../domain/TxtEncoding';

export type BatchImportPhase = 'idle' | 'review' | 'running' | 'results';
export type BatchImportItemStatus = 'pending' | 'active' | 'stored' | 'restored' | 'duplicate' |
  'rejected' | 'failed' | 'cancelled' | 'not-started';

export interface BatchImportItemSnapshot {
  id: number;
  label: string;
  status: BatchImportItemStatus;
  message?: string;
  book?: Book;
  txtEncoding?: TxtEncodingChoice;
  txtReady?: boolean;
  txtMessage?: string;
}

export interface BatchImportSnapshot {
  phase: BatchImportPhase;
  items: BatchImportItemSnapshot[];
  activeIndex: number;
  limit: number;
  targetFolderId?: string;
  message?: string;
}

interface BatchImportItem extends BatchImportItemSnapshot {
  uri: string;
}

export type BatchImportObserver = (snapshot: BatchImportSnapshot) => void;

function displayName(uri: string): string {
  const normalized = uri.replace(/\\/g, '/');
  const encoded = normalized.substring(normalized.lastIndexOf('/') + 1).split('?')[0];
  try { return decodeURIComponent(encoded); } catch (_) { return '未命名书籍'; }
}

function isRejected(result: ImportResult): boolean {
  return result.status === 'not_epub' || result.status === 'malformed' || result.status === 'encrypted' ||
    result.status === 'resource_limit' || result.status === 'unsupported_encoding' ||
    result.status === 'unsupported_resource';
}

export class BatchImportCoordinator {
  private service: BookImportService;
  private items: BatchImportItem[] = [];
  private phase: BatchImportPhase = 'idle';
  private targetFolderId: string = ROOT_FOLDER;
  private activeIndex: number = -1;
  private nextId: number = 1;
  private message?: string;
  private cancelRequested: boolean = false;
  private foreground: boolean = true;
  private activeControl?: ImportCancellation;
  private resumeNext?: () => void;

  constructor(service: BookImportService) { this.service = service; }

  snapshot(): BatchImportSnapshot {
    return {
      phase: this.phase,
      items: this.items.map((item: BatchImportItem): BatchImportItemSnapshot => ({
        id: item.id, label: item.label, status: item.status, message: item.message, book: item.book,
        txtEncoding: item.txtEncoding, txtReady: item.txtReady, txtMessage: item.txtMessage
      })),
      activeIndex: this.activeIndex,
      limit: VISIBLE_IMPORT_BATCH_LIMIT,
      targetFolderId: this.phase === 'idle' ? undefined : this.targetFolderId,
      message: this.message
    };
  }

  isRunning(): boolean { return this.phase === 'running'; }

  addSelection(uris: string[], targetFolderId: string = ROOT_FOLDER): BatchImportSnapshot {
    if (this.phase !== 'idle' && this.phase !== 'review') return this.snapshot();
    const additions: string[] = [];
    for (const uri of uris) {
      if (uri.length === 0 || this.items.some((item: BatchImportItem): boolean => item.uri === uri) ||
        additions.includes(uri)) continue;
      additions.push(uri);
    }
    if (this.phase === 'review' && additions.length > 0 && targetFolderId !== this.targetFolderId) {
      this.message = '本批次的导入目录已固定，请返回原目录添加，或取消后重新选择。';
      return this.snapshot();
    }
    if (this.items.length + additions.length > VISIBLE_IMPORT_BATCH_LIMIT) {
      this.message = `一次最多添加 ${VISIBLE_IMPORT_BATCH_LIMIT} 本；本次选择未加入。`;
      return this.snapshot();
    }
    if (this.phase === 'idle' && additions.length > 0) this.targetFolderId = targetFolderId;
    for (const uri of additions) {
      const label = displayName(uri);
      const isTxt = label.toLowerCase().endsWith('.txt');
      this.items.push({ id: this.nextId++, uri: uri, label: label, status: 'pending',
        txtEncoding: isTxt ? 'auto' : undefined, txtReady: isTxt ? false : undefined });
    }
    if (this.items.length > 0) this.phase = 'review';
    this.message = undefined;
    return this.snapshot();
  }

  remove(id: number): BatchImportSnapshot {
    if (this.phase !== 'review') return this.snapshot();
    this.items = this.items.filter((item: BatchImportItem): boolean => item.id !== id);
    if (this.items.length === 0) {
      this.phase = 'idle';
      this.targetFolderId = ROOT_FOLDER;
    }
    this.message = undefined;
    return this.snapshot();
  }

  async checkTextEncoding(): Promise<BatchImportSnapshot> {
    if (this.phase !== 'review') return this.snapshot();
    for (const item of this.items) {
      if (this.phase !== 'review') break;
      if (item.txtEncoding === undefined || item.txtReady !== false || item.txtMessage !== undefined) continue;
      const preview = await this.service.previewText(item.uri, 'auto');
      if (this.phase !== 'review' || !this.items.includes(item)) continue;
      item.txtReady = preview.valid;
      item.txtMessage = preview.valid ? undefined : preview.message;
    }
    return this.snapshot();
  }

  async previewText(id: number, encoding: TxtEncodingChoice): Promise<TxtPreview> {
    const item = this.items.find((candidate: BatchImportItem): boolean => candidate.id === id);
    if (this.phase !== 'review' || item?.txtEncoding === undefined) {
      return { valid: false, excerpt: '', encoding: encoding, message: '这本书已离开导入列表。' };
    }
    return this.service.previewText(item.uri, encoding);
  }

  setTextEncoding(id: number, encoding: TxtEncodingChoice): BatchImportSnapshot {
    if (this.phase !== 'review') return this.snapshot();
    const item = this.items.find((candidate: BatchImportItem): boolean => candidate.id === id);
    if (item?.txtEncoding !== undefined) {
      item.txtEncoding = encoding;
      item.txtReady = true;
      item.txtMessage = undefined;
    }
    return this.snapshot();
  }

  cancelReview(): BatchImportSnapshot {
    if (this.phase === 'review') this.clear();
    return this.snapshot();
  }

  resetResults(): BatchImportSnapshot {
    if (this.phase === 'results') this.clear();
    return this.snapshot();
  }

  cancel(): boolean {
    if (this.phase !== 'running') return false;
    this.cancelRequested = true;
    if (this.activeControl !== undefined) this.activeControl.cancelled = true;
    this.resumeNext?.();
    this.resumeNext = undefined;
    return true;
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    if (foreground) {
      this.resumeNext?.();
      this.resumeNext = undefined;
    }
  }

  async confirm(observer: BatchImportObserver): Promise<BatchImportSnapshot> {
    if (this.phase !== 'review' || this.items.length === 0 ||
      this.items.some((item: BatchImportItem): boolean => item.txtReady === false)) return this.snapshot();
    const targetFolderId = this.targetFolderId;
    this.phase = 'running';
    this.activeIndex = -1;
    this.cancelRequested = false;
    this.message = undefined;
    observer(this.snapshot());
    for (let index = 0; index < this.items.length; index++) {
      await this.waitUntilForeground();
      if (this.cancelRequested) { this.markNotStarted(index); break; }
      const item = this.items[index];
      this.activeIndex = index;
      item.status = 'active';
      const control = new ImportCancellation();
      this.activeControl = control;
      observer(this.snapshot());
      const result = await this.service.import(item.uri, control, item.txtEncoding ?? 'auto');
      this.activeControl = undefined;
      const stop = await this.finishItem(item, result, control, targetFolderId);
      observer(this.snapshot());
      if (stop || this.cancelRequested) { this.markNotStarted(index + 1); break; }
    }
    this.activeIndex = -1;
    this.phase = 'results';
    observer(this.snapshot());
    return this.snapshot();
  }

  private async finishItem(item: BatchImportItem, result: ImportResult,
    control: ImportCancellation, targetFolderId: string): Promise<boolean> {
    if (result.status === 'duplicate') {
      item.status = 'duplicate'; item.book = result.book; return false;
    }
    if ((result.status === 'prepared-new' || result.status === 'prepared-repair') && result.book !== undefined &&
      result.operationId !== undefined && result.operationKind !== undefined) {
      if (control.isCancelled()) {
        const clean = await this.service.rollbackPrepared(result.operationId, result.book.bookId);
        item.status = 'cancelled';
        item.message = clean ? result.message : '取消后的临时文件待清理。';
        return !clean;
      }
      try {
        await this.service.commitPrepared(result.operationId, result.operationKind, result.book, targetFolderId);
        item.status = result.status === 'prepared-repair' ? 'restored' : 'stored';
        if (item.status === 'restored') result.book.sourceState = 'available';
        item.book = result.book;
        return false;
      } catch (_) {
        const clean = await this.service.rollbackPrepared(result.operationId, result.book.bookId);
        item.status = 'failed';
        item.message = clean ? '导入未完成，请重试。' : '导入未完成，请重新选择文件。';
        return !clean;
      }
    }
    item.message = result.message;
    if (result.status === 'cancelled') item.status = 'cancelled';
    else if (isRejected(result)) item.status = 'rejected';
    else item.status = 'failed';
    return result.status === 'cleanup_pending' || result.status === 'cancelled';
  }

  private markNotStarted(from: number): void {
    for (let index = from; index < this.items.length; index++) {
      if (this.items[index].status === 'pending') this.items[index].status = 'not-started';
    }
  }

  private async waitUntilForeground(): Promise<void> {
    if (this.foreground || this.cancelRequested) return;
    await new Promise<void>((resolve): void => { this.resumeNext = resolve; });
  }

  private clear(): void {
    this.items = [];
    this.phase = 'idle';
    this.targetFolderId = ROOT_FOLDER;
    this.activeIndex = -1;
    this.message = undefined;
    this.cancelRequested = false;
  }
}
