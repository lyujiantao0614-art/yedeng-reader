import { common } from '@kit.AbilityKit';
import { Book, PageBookmarkExcerpt, TextMarkKind, TextMarkRecord, WEB_READER_ENGINE_ID } from '../domain/Models';
import { ReadingSelectionContext } from '../reader/ReadingSelectionModels';
import { EncryptedBookmarkStore } from '../repositories/EncryptedBookmarkStore';
import { LibraryRepository } from '../repositories/LibraryRepository';
import { createSecureUuid } from '../services/ManagedBookStore';

export class TextMarkApplication {
  private repository: LibraryRepository;
  private encrypted: EncryptedBookmarkStore;
  private context?: common.Context;
  private preparing?: Promise<void>;

  constructor(repository: LibraryRepository, encrypted: EncryptedBookmarkStore) {
    this.repository = repository;
    this.encrypted = encrypted;
  }

  initialize(context: common.Context): void { this.context = context; }

  private async prepareStore(): Promise<void> {
    if (await this.repository.textRecordsEnabled()) {
      this.encrypted.ensureAvailable();
      return;
    }
    if (await this.repository.bookmarkAuthority() === 'target') {
      this.encrypted.ensureAvailable();
      await this.repository.enableTextRecords();
      return;
    }
    if (this.context === undefined) throw new Error('Record store context unavailable');
    await this.encrypted.createForMigration(this.context);
    await this.repository.enableTextRecords();
  }

  private async ensureWritable(): Promise<void> {
    if (this.preparing === undefined) {
      this.preparing = this.prepareStore().finally((): void => { this.preparing = undefined; });
    }
    await this.preparing;
  }

  private async bookCanReceiveMark(bookId: string): Promise<boolean> {
    if (await this.repository.getBook(bookId) === undefined) return false;
    return !(await this.repository.listOperations()).some((operation): boolean =>
      operation.kind === 'delete' && operation.bookId === bookId);
  }

  async list(bookId: string): Promise<TextMarkRecord[]> {
    if (!await this.repository.textRecordsEnabled()) return [];
    return this.encrypted.listTextMarks(bookId);
  }

  async listPageExcerpts(bookId: string): Promise<PageBookmarkExcerpt[]> {
    if (!await this.repository.textRecordsEnabled()) return [];
    return this.encrypted.listPageExcerpts(bookId);
  }

  async savePageExcerpt(bookId: string, bookmarkId: string, excerpt: string): Promise<void> {
    if (excerpt.length === 0 || excerpt.length > 240 || bookmarkId.length > 96 ||
      !await this.bookCanReceiveMark(bookId)) throw new Error('Invalid page excerpt');
    await this.ensureWritable();
    if (!await this.bookCanReceiveMark(bookId)) throw new Error('Book unavailable');
    await this.encrypted.insertPageExcerpt({ bookmarkId, bookId, excerpt });
    if (!await this.bookCanReceiveMark(bookId)) {
      await this.encrypted.removePageExcerpt(bookId, bookmarkId);
      throw new Error('Book unavailable');
    }
  }

  async removePageExcerpt(bookId: string, bookmarkId: string): Promise<void> {
    if (!await this.repository.textRecordsEnabled()) return;
    await this.encrypted.removePageExcerpt(bookId, bookmarkId);
  }

  async save(book: Book, context: ReadingSelectionContext,
    kind: TextMarkKind, noteText: string = ''): Promise<TextMarkRecord> {
    const anchor = context.rangeAnchor;
    if (book.sourceState !== 'available' || anchor === undefined ||
      context.selectedText !== anchor.exactText.trim() || anchor.exactText.length === 0 ||
      anchor.exactText.length > 512 || anchor.prefix.length > 64 || anchor.suffix.length > 64 ||
      anchor.cfi.length === 0 || anchor.cfi.length > 4096 ||
      !anchor.cfi.startsWith('epubcfi(') || anchor.resourceHref.length === 0 ||
      anchor.resourceHref.length > 512 || (kind !== 'highlight' && kind !== 'note') ||
      noteText.length > 2000 || (kind === 'note' && noteText.trim().length === 0)) {
      throw new Error('Invalid selected text record');
    }
    if (!await this.bookCanReceiveMark(book.bookId)) throw new Error('Book unavailable');
    await this.ensureWritable();
    const record: TextMarkRecord = {
      markId: createSecureUuid(), bookId: book.bookId, anchorVersion: 1,
      engine: WEB_READER_ENGINE_ID, resourceHref: anchor.resourceHref, cfi: anchor.cfi,
      exactText: anchor.exactText, prefix: anchor.prefix, suffix: anchor.suffix,
      kind, chapterTitle: (context.chapterTitle ?? book.title).slice(0, 256),
      noteText: kind === 'note' ? noteText.trim() : '', createdAt: Date.now()
    };
    if (!await this.bookCanReceiveMark(book.bookId)) throw new Error('Book unavailable');
    await this.encrypted.insertTextMark(record);
    if (!await this.bookCanReceiveMark(book.bookId)) {
      await this.encrypted.removeTextMark(book.bookId, record.markId);
      throw new Error('Book unavailable');
    }
    return record;
  }

  async remove(bookId: string, markId: string): Promise<void> {
    if (!await this.repository.textRecordsEnabled()) return;
    await this.encrypted.removeTextMark(bookId, markId);
  }

  async revise(mark: TextMarkRecord, context?: ReadingSelectionContext,
    kind?: TextMarkKind, noteText?: string): Promise<TextMarkRecord> {
    if (!await this.repository.textRecordsEnabled() || !await this.bookCanReceiveMark(mark.bookId)) {
      throw new Error('Text mark unavailable');
    }
    const current = (await this.encrypted.listTextMarks(mark.bookId)).find((item: TextMarkRecord): boolean =>
      item.markId === mark.markId);
    if (current === undefined || current.cfi !== mark.cfi || current.exactText !== mark.exactText ||
      current.kind !== mark.kind) throw new Error('Text mark changed');
    const anchor = context?.rangeAnchor;
    if (context !== undefined && (anchor === undefined ||
      context.selectedText !== anchor.exactText.trim() || anchor.exactText.length === 0 ||
      anchor.exactText.length > 512 || anchor.cfi.length === 0 || anchor.cfi.length > 4096 ||
      !anchor.cfi.startsWith('epubcfi(') || anchor.resourceHref !== current.resourceHref ||
      anchor.prefix.length > 64 || anchor.suffix.length > 64)) {
      throw new Error('Invalid replacement range');
    }
    const nextKind = kind ?? current.kind;
    const nextNote = noteText === undefined ? current.noteText : noteText.trim();
    if ((nextKind !== 'note' && nextKind !== 'highlight') ||
      (nextKind === 'note' && (nextNote.length === 0 || nextNote.length > 2000))) {
      throw new Error('Invalid note');
    }
    const revised: TextMarkRecord = {
      markId: current.markId, bookId: current.bookId, anchorVersion: current.anchorVersion,
      engine: current.engine, resourceHref: current.resourceHref,
      cfi: anchor?.cfi ?? current.cfi, exactText: anchor?.exactText ?? current.exactText,
      prefix: anchor?.prefix ?? current.prefix, suffix: anchor?.suffix ?? current.suffix,
      kind: nextKind, chapterTitle: context?.chapterTitle ?? current.chapterTitle,
      noteText: nextKind === 'note' ? nextNote : '', createdAt: current.createdAt
    };
    await this.encrypted.updateTextMarkRecord(revised, current);
    return revised;
  }

  async retainRecoveredCfi(mark: TextMarkRecord, recoveredCfi: string): Promise<TextMarkRecord> {
    if (!await this.repository.textRecordsEnabled() ||
      !recoveredCfi.startsWith('epubcfi(') || recoveredCfi.length > 4096) {
      throw new Error('Invalid recovered locator');
    }
    const current = (await this.encrypted.listTextMarks(mark.bookId)).find((item: TextMarkRecord): boolean =>
      item.markId === mark.markId);
    if (current === undefined || current.cfi !== mark.cfi ||
      current.resourceHref !== mark.resourceHref || current.exactText !== mark.exactText) {
      throw new Error('Text mark changed before recovery');
    }
    const recovered: TextMarkRecord = {
      markId: current.markId, bookId: current.bookId, anchorVersion: current.anchorVersion,
      engine: current.engine, resourceHref: current.resourceHref, cfi: recoveredCfi,
      exactText: current.exactText, prefix: current.prefix, suffix: current.suffix,
      kind: current.kind, chapterTitle: current.chapterTitle, noteText: current.noteText,
      createdAt: current.createdAt
    };
    await this.encrypted.updateTextMarkAnchor(recovered, current.cfi);
    return recovered;
  }

  async reanchor(mark: TextMarkRecord, context: ReadingSelectionContext): Promise<TextMarkRecord> {
    const anchor = context.rangeAnchor;
    if (!await this.repository.textRecordsEnabled() || anchor === undefined ||
      context.kind !== 'passage' || context.selectedText !== mark.exactText.trim() ||
      anchor.exactText !== mark.exactText ||
      anchor.resourceHref !== mark.resourceHref || !anchor.cfi.startsWith('epubcfi(') ||
      anchor.cfi.length > 4096 || anchor.prefix.length > 64 || anchor.suffix.length > 64 ||
      !await this.bookCanReceiveMark(mark.bookId)) {
      throw new Error('Selected range cannot repair this mark');
    }
    const current = (await this.encrypted.listTextMarks(mark.bookId)).find((item: TextMarkRecord): boolean =>
      item.markId === mark.markId);
    if (current === undefined || current.cfi !== mark.cfi ||
      current.resourceHref !== mark.resourceHref || current.exactText !== mark.exactText) {
      throw new Error('Text mark changed before repair');
    }
    const repaired: TextMarkRecord = {
      markId: current.markId, bookId: current.bookId, anchorVersion: current.anchorVersion,
      engine: current.engine, resourceHref: current.resourceHref, cfi: anchor.cfi,
      exactText: current.exactText, prefix: anchor.prefix, suffix: anchor.suffix,
      kind: current.kind, chapterTitle: (context.chapterTitle ?? current.chapterTitle).slice(0, 256),
      noteText: current.noteText, createdAt: current.createdAt
    };
    await this.encrypted.updateTextMarkAnchor(repaired, current.cfi);
    return repaired;
  }
}
