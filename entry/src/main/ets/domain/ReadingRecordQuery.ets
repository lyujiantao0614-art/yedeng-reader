import { BookmarkPoint } from './Models';

export interface RecordCursor { time: number; id: string; }
export interface RecordPage<T> { items: T[]; next?: RecordCursor; }
export interface NoteSummary {
  noteId: string; bookId: string; quote: string; excerpt: string; createdAt: number; updatedAt: number;
}
export interface BookmarkRecordPage extends RecordPage<BookmarkPoint> { authority: 'source' | 'target'; }
export function recordPageSize(size: number): number {
  return Number.isFinite(size) ? Math.max(1, Math.min(20, Math.floor(size))) : 20;
}
