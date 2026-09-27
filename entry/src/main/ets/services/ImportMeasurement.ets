import { systemDateTime } from '@kit.BasicServicesKit';

export type ImportMeasuredStage = 'copy_hash' | 'archive_preflight' | 'extraction' |
  'xml_resources' | 'final_epub_copy' | 'cover_copy' | 'final_move' | 'cleanup' | 'commit';
export interface ImportMeasurementObserver {
  completed(stage: ImportMeasuredStage, milliseconds: number, succeeded: boolean): void;
}

// No log sink, identifiers or publication data. A caller explicitly supplies the
// observer; observer failures cannot change a storage transaction's outcome.
export async function measureImportStage<T>(observer: ImportMeasurementObserver | undefined,
  stage: ImportMeasuredStage, work: () => Promise<T>): Promise<T> {
  if (observer === undefined) return work();
  const started = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
  let succeeded = false;
  try {
    const result = await work();
    succeeded = true;
    return result;
  } finally {
    const elapsed = Math.max(0, systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) - started);
    try { observer.completed(stage, elapsed, succeeded); } catch (_) {}
  }
}