export type ReaderOpenColdWarm = 'cold' | 'warm';
export type ReaderOpenEpubSizeBucket = 'small' | 'medium' | 'large' | 'unknown';
export type ReaderOpenRestoreDepthBucket = 'start' | 'shallow' | 'deep' | 'unknown';
export type ReaderOpenErrorCategory =
  'book-response' | 'bridge-initialization' | 'bridge-page' | 'bridge-protocol' |
  'reader-command' | 'reader-engine' | 'reader-session' | 'shell-page';

export type ReaderOpenStage =
  'open_requested' | 'host_created' | 'host_reused' | 'controller_attached' |
  'controller_reused' | 'bridge_committed' | 'bridge_reused' | 'shell_committed' |
  'book_response_started' | 'book_response_finished' | 'epub_parsed' |
  'rendition_created' | 'restore_started' | 'first_relocation' |
  'restore_finished' | 'viewer_committed' | 'reader_ready' | 'open_failed';

export type WebReaderOpenStage =
  'shell_committed' | 'book_response_finished' | 'epub_parsed' |
  'rendition_created' | 'restore_started' | 'first_relocation' |
  'restore_finished' | 'viewer_committed';

export interface ReaderOpenScenario {
  coldWarm: ReaderOpenColdWarm;
  epubSize: ReaderOpenEpubSizeBucket;
  restoreDepth: ReaderOpenRestoreDepthBucket;
}

export const SMALL_EPUB_MAX_BYTES: number = 1024 * 1024;
export const MEDIUM_EPUB_MAX_BYTES: number = 20 * 1024 * 1024;

const WEB_READER_OPEN_STAGES: WebReaderOpenStage[] = [
  'shell_committed',
  'book_response_finished',
  'epub_parsed',
  'rendition_created',
  'restore_started',
  'first_relocation',
  'restore_finished',
  'viewer_committed'
];

export function classifyReaderOpenEpubSize(bytes?: number): ReaderOpenEpubSizeBucket {
  if (bytes === undefined || !Number.isFinite(bytes) || bytes < 0) return 'unknown';
  if (bytes <= SMALL_EPUB_MAX_BYTES) return 'small';
  if (bytes <= MEDIUM_EPUB_MAX_BYTES) return 'medium';
  return 'large';
}

export function classifyReaderOpenRestoreDepth(percentage?: number): ReaderOpenRestoreDepthBucket {
  if (percentage === undefined) return 'start';
  if (!Number.isFinite(percentage)) return 'unknown';
  if (percentage <= 0) return 'start';
  if (percentage <= 0.25) return 'shallow';
  return 'deep';
}

export function isWebReaderOpenStage(value: string): boolean {
  for (const stage of WEB_READER_OPEN_STAGES) {
    if (stage === value) return true;
  }
  return false;
}
