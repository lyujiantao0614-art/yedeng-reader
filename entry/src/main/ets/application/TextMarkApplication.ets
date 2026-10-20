import { common } from '@kit.AbilityKit';
import { Book, PageBookmarkExcerpt, TextMarkKind, TextMarkRecord, NoteEntry, RangeAnchorStatus, TextRangeAnchor, NoteAnchorProvenance, copyTextRangeAnchor, WEB_READER_ENGINE_ID } from '../domain/Models';
import { ReadingRangeCandidate, ReadingSelectionContext } from '../reader/ReadingSelectionModels';
import { EncryptedBookmarkStore } from '../repositories/EncryptedBookmarkStore';
import { LibraryRepository } from '../repositories/LibraryRepository';
import { createSecureUuid } from '../services/ManagedBookStore';
import { NoteSummary, RecordCursor, RecordPage } from '../domain/ReadingRecordQuery';

export const RANGE_QUOTE_LIMIT: number = 32768;
export class TextMarkApplication {
  private repository: LibraryRepository;
  private encrypted: EncryptedBookmarkStore;
  private context?: common.Context;
  private preparing?: Promise<void>;
  constructor(repository: LibraryRepository, encrypted: EncryptedBookmarkStore) {
    this.repository = repository; this.encrypted = encrypted;
  }
  initialize(context: common.Context): void { this.context = context; }
  private async prepareStore(): Promise<void> {
    if (await this.repository.textRecordsEnabled() || await this.repository.bookmarkAuthority() === 'target') {
      this.encrypted.ensureAvailable();
      if (this.encrypted.databaseVersion() !== 5) throw new Error('Range store unavailable');
    } else {
      if (!this.context) throw new Error('Record context unavailable');
      await this.encrypted.createForMigration(this.context);
    }
    // The target committed/verified its copy receipt before this separate catalogue cutover.
    if (await this.repository.rangeRecordsVersion() !== 4) await this.repository.activateRangeRecords();
    if (!await this.repository.textRecordsEnabled()) await this.repository.enableTextRecords();
  }
  private async ensureWritable(): Promise<void> {
    if (!this.preparing) this.preparing = this.prepareStore().finally((): void => { this.preparing = undefined; });
    await this.preparing;
  }
  private async bookCanReceiveMark(bookId: string): Promise<boolean> {
    return await this.repository.getBook(bookId) !== undefined && !(await this.repository.listOperations())
      .some((operation): boolean => operation.kind === 'delete' && operation.bookId === bookId);
  }
  async list(bookId: string): Promise<TextMarkRecord[]> {
    if (!await this.repository.textRecordsEnabled()) return [];
    await this.ensureWritable();
    return this.encrypted.listTextMarks(bookId);
  }

  async notePage(cursor?: RecordCursor): Promise<RecordPage<NoteSummary>> {
    if (!await this.repository.textRecordsEnabled()) return { items: [] };
    await this.ensureWritable();
    return this.encrypted.notePage(cursor);
  }

  async noteDetail(bookId: string, noteId: string): Promise<NoteEntry | undefined> {
    if (!await this.repository.textRecordsEnabled()) return undefined;
    await this.ensureWritable();
    return this.encrypted.noteDetail(bookId, noteId);
  }
  async listPageExcerpts(bookId: string): Promise<PageBookmarkExcerpt[]> {
    if (!await this.repository.textRecordsEnabled()) return [];
    return this.encrypted.listPageExcerpts(bookId);
  }
  async savePageExcerpt(bookId: string, bookmarkId: string, excerpt: string): Promise<void> {
    if (!excerpt || excerpt.length > 240 || bookmarkId.length > 96 || !await this.bookCanReceiveMark(bookId)) throw new Error('Invalid page excerpt');
    await this.ensureWritable();
    if (!await this.bookCanReceiveMark(bookId)) throw new Error('Book unavailable');
    await this.encrypted.insertPageExcerpt({ bookmarkId, bookId, excerpt });
    if (!await this.bookCanReceiveMark(bookId)) { await this.encrypted.removePageExcerpt(bookId,bookmarkId); throw new Error('Book unavailable'); }
  }
  async removePageExcerpt(bookId: string, bookmarkId: string): Promise<void> {
    if (await this.repository.textRecordsEnabled()) await this.encrypted.removePageExcerpt(bookId,bookmarkId);
  }
  private validAnchor(anchor?: ReadingRangeCandidate): boolean {
    return anchor !== undefined && anchor.exactText.length > 0 && anchor.exactText.length <= RANGE_QUOTE_LIMIT &&
      anchor.prefix.length <= 64 && anchor.suffix.length <= 64 && anchor.cfi.startsWith('epubcfi(') &&
      anchor.cfi.length <= 4096 && anchor.resourceHref.length > 0 && anchor.resourceHref.length <= 512;
  }
  private validateContext(context: ReadingSelectionContext): ReadingRangeCandidate {
    if (!this.validAnchor(context.rangeAnchor) || context.rangeAnchor!.exactText.trim() !== context.selectedText ||
      context.markConflict !== undefined) throw new Error('Invalid verified selection');
    const anchor = context.rangeUnion ?? context.rangeAnchor!;
    if (!this.validAnchor(anchor) || anchor.resourceHref !== context.rangeAnchor!.resourceHref) throw new Error('Invalid union anchor');
    return anchor;
  }
  private async members(bookId: string, context: ReadingSelectionContext,kind: TextMarkKind): Promise<TextMarkRecord[]> {
    const expected = context.rangeUnion?.members ?? [];
    if (expected.length > 150 || new Set(expected.map((member): string => member.markId)).size !== expected.length) throw new Error('Invalid union members');
    const current = await this.list(bookId), result: TextMarkRecord[] = [];
    for (const member of expected) {
      const mark = current.find((item: TextMarkRecord): boolean => item.markId === member.markId);
      if (!mark || mark.kind !== kind || mark.resourceHref !== context.rangeAnchor!.resourceHref || mark.revision !== member.revision) throw new Error('Union changed');
      result.push(mark);
    }
    return result;
  }
  private note(bookId: string, rangeId: string, body: string, originalAnchor: TextRangeAnchor,
    anchorProvenance: NoteAnchorProvenance): NoteEntry {
    if (!body.trim() || body.length > 2000) throw new Error('Invalid note');
    const now = Date.now();
    return { noteId: createSecureUuid(),bookId,rangeId,body,createdAt: now,updatedAt: now,revision: 1,
      originalAnchor,anchorProvenance,anchorStatus: anchorProvenance === 'selection' ? 'verified' : 'unchecked' };
  }
  async save(book: Book, context: ReadingSelectionContext, kind: TextMarkKind, noteText: string = ''): Promise<TextMarkRecord> {
    const anchor = this.validateContext(context);
    if (book.sourceState !== 'available' || !await this.bookCanReceiveMark(book.bookId) ||
      (kind !== 'note' && kind !== 'highlight')) throw new Error('Book unavailable');
    await this.ensureWritable();
    const expected = await this.members(book.bookId,context,kind);
    const first = expected[0];
    const mark: TextMarkRecord = { markId: first?.markId ?? createSecureUuid(), bookId: book.bookId, anchorVersion: 1,
      engine: WEB_READER_ENGINE_ID,resourceHref: anchor.resourceHref,cfi: anchor.cfi,exactText: anchor.exactText,
      prefix: anchor.prefix,suffix: anchor.suffix,kind,chapterTitle: (context.chapterTitle ?? book.title).slice(0,256),
      noteText: '',createdAt: first?.createdAt ?? Date.now(),highlightActive: kind === 'highlight' || expected.some((item: TextMarkRecord): boolean => item.highlightActive === true),
      anchorStatus: 'verified',quoteScope: anchor.quoteScope ?? 'block' };
    mark.highlightAnchors = kind === 'highlight' ? [copyTextRangeAnchor(mark)] : expected.flatMap((item: TextMarkRecord): TextRangeAnchor[] => item.highlightAnchors ?? []);
    const selected = context.rangeAnchor!;
    const original: TextRangeAnchor = {anchorVersion: 1,engine: WEB_READER_ENGINE_ID,resourceHref: selected.resourceHref,
      cfi: selected.cfi,exactText: selected.exactText,prefix: selected.prefix,suffix: selected.suffix,quoteScope: selected.quoteScope ?? 'block'};
    const note = kind === 'note' ? this.note(book.bookId,mark.markId,noteText,original,'selection') : undefined;
    if (!await this.bookCanReceiveMark(book.bookId)) throw new Error('Book unavailable');
    return await this.encrypted.replaceRanges(mark,expected,note,(): Promise<boolean> => this.bookCanReceiveMark(book.bookId));
  }
  async remove(bookId: string, markId: string): Promise<void> {
    if (await this.repository.textRecordsEnabled()) await this.encrypted.removeTextMark(bookId,markId);
  }
  async addNote(mark: TextMarkRecord, body: string): Promise<void> {
    await this.ensureWritable();
    if (!await this.bookCanReceiveMark(mark.bookId)) throw new Error('Book unavailable');
    await this.encrypted.addNote(this.note(mark.bookId,mark.markId,body,copyTextRangeAnchor(mark),'range-attachment'));
  }
  async editNote(note: NoteEntry, body: string): Promise<void> {
    if (!body.trim() || body.length > 2000 || !await this.bookCanReceiveMark(note.bookId)) throw new Error('Invalid note');
    await this.encrypted.editNote(note,body);
  }
  async removeNote(note: NoteEntry): Promise<void> { await this.encrypted.removeNote(note); }
  async setNoteAnchorStatus(note: NoteEntry,status: RangeAnchorStatus): Promise<void> {
    if (await this.repository.textRecordsEnabled()) await this.encrypted.setNoteAnchorStatus(note,status);
  }
  async setAnchorStatus(mark: TextMarkRecord, status: RangeAnchorStatus): Promise<void> {
    if (await this.repository.textRecordsEnabled()) await this.encrypted.setAnchorStatus(mark,status);
  }
  async revise(mark: TextMarkRecord, context?: ReadingSelectionContext, kind?: TextMarkKind, noteText?: string): Promise<TextMarkRecord> {
    await this.ensureWritable();
    const current = (await this.list(mark.bookId)).find((item: TextMarkRecord): boolean => item.markId === mark.markId);
    if (!current || current.cfi !== mark.cfi || current.exactText !== mark.exactText ||
      (mark.revision !== undefined && current.revision !== mark.revision) || !await this.bookCanReceiveMark(mark.bookId)) throw new Error('Range changed');
    if (context) {
      const anchor = this.validateContext(context);
      if (anchor.resourceHref !== current.resourceHref) throw new Error('Cross-resource revision');
      const expected = await this.members(mark.bookId,context,current.kind);
      if (!expected.some((item: TextMarkRecord): boolean => item.markId === current.markId)) expected.push(current);
      const revised: TextMarkRecord = { markId: current.markId,bookId: current.bookId,anchorVersion: 1,engine: current.engine,
        resourceHref: anchor.resourceHref,cfi: anchor.cfi,exactText: anchor.exactText,prefix: anchor.prefix,suffix: anchor.suffix,
        kind: current.kind,chapterTitle: (context.chapterTitle ?? current.chapterTitle).slice(0,256),noteText: '',
        createdAt: current.createdAt,highlightActive: current.highlightActive,anchorStatus: 'verified',quoteScope: anchor.quoteScope ?? 'block',
        highlightAnchors: expected.flatMap((item: TextMarkRecord): TextRangeAnchor[] => item.highlightAnchors ?? []) };
      if (current.kind === 'highlight') revised.highlightAnchors = [copyTextRangeAnchor(revised)];
      const committed = await this.encrypted.replaceRanges(revised,expected,undefined,(): Promise<boolean> => this.bookCanReceiveMark(mark.bookId));
      // Ordinary range adjustment ends at its resolved commit; presentation reads cannot turn it into a failed write.
      if (kind === undefined) return committed;
    }
    // Compatibility caller edits one existing entry; the product UI uses explicit NoteEntry IDs.
    if (kind === 'note' && noteText !== undefined) {
      const notes = (await this.list(mark.bookId)).find((item: TextMarkRecord): boolean => item.markId === current.markId)?.notes ?? [];
      if (notes[0]) await this.editNote(notes[0],noteText); else await this.addNote(current,noteText);
    }
    if (kind === 'highlight') await this.remove(mark.bookId,mark.markId);
    return (await this.list(mark.bookId)).find((item: TextMarkRecord): boolean => item.markId === current.markId)!;
  }
  async retainRecoveredCfi(mark: TextMarkRecord, recoveredCfi: string): Promise<TextMarkRecord> {
    if (!recoveredCfi.startsWith('epubcfi(') || recoveredCfi.length > 4096) throw new Error('Invalid recovered locator');
    const current = (await this.list(mark.bookId)).find((item: TextMarkRecord): boolean => item.markId === mark.markId);
    if (!current || current.cfi !== mark.cfi || current.exactText !== mark.exactText ||
      (current.revision ?? 1) !== (mark.revision ?? 1)) throw new Error('Range changed');
    const recovered: TextMarkRecord = { markId: current.markId,bookId: current.bookId,anchorVersion: 1,engine: current.engine,
      resourceHref: current.resourceHref,cfi: recoveredCfi,exactText: current.exactText,prefix: current.prefix,suffix: current.suffix,
      kind: current.kind,chapterTitle: current.chapterTitle,noteText: '',createdAt: current.createdAt,
      highlightActive: current.highlightActive,anchorStatus: 'verified',quoteScope: current.quoteScope,highlightAnchors: current.highlightAnchors };
    return await this.encrypted.replaceRanges(recovered,[current],undefined,(): Promise<boolean> => this.bookCanReceiveMark(mark.bookId));
  }
  async reanchor(mark: TextMarkRecord, context: ReadingSelectionContext): Promise<TextMarkRecord> {
    if (context.rangeAnchor?.exactText !== mark.exactText) throw new Error('Different quote');
    return this.revise(mark,context);
  }
}
