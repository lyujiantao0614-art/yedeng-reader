import { worker, MessageEvents } from '@kit.ArkTS';
import { BoundedInflateError, InflateControl } from './BoundedInflater';
import { EpubInputError, EpubInputFailure } from './EpubInputPolicy';
import { EpubInspection, EpubInspectionError } from './EpubInspector';
import { EpubResourceLimits } from './EpubResourceInspector';
import { ZipEntry } from './EpubZipIndex';

export interface EpubWorkerRequest {
  kind: 'inspect'; root: string; xmlBytes: number;
  limits: EpubResourceLimits; entries: ZipEntry[];
}
export interface EpubWorkerCancel { kind: 'cancel'; }
export type EpubWorkerMessage = EpubWorkerRequest | EpubWorkerCancel;
export interface EpubWorkerResult {
  status: 'ok' | 'cancelled' | 'io_error' | 'not_epub' | EpubInputFailure;
  inspection?: EpubInspection;
}

// One read-only inspection per Worker lifetime. Resolve only after onexit,
// before the caller copies final assets, commits, or removes inspection staging.
export async function inspectEpubInWorker(root: string, xmlBytes: number,
  limits: EpubResourceLimits, entries: ZipEntry[], control: InflateControl): Promise<EpubInspection> {
  if (control.isCancelled()) throw new BoundedInflateError('cancelled');
  const thread = new worker.ThreadWorker('entry/ets/workers/EpubInspectionWorker.ets', { name: 'EpubInspection' });
  return new Promise<EpubInspection>((resolve, reject): void => {
    let result: EpubWorkerResult | undefined;
    let failed = false;
    let unsubscribe: (() => void) | undefined;
    const stop = (): void => { failed = true; try { thread.terminate(); } catch (_) {} };
    thread.onmessage = (event: MessageEvents): void => { result = event.data as EpubWorkerResult; };
    thread.onerror = (): void => { stop(); };
    thread.onmessageerror = (): void => { stop(); };
    thread.onexit = (code: number): void => {
      unsubscribe?.();
      if (failed || code !== 0 || result === undefined) { reject(new Error('EPUB inspection worker failed')); return; }
      if (control.isCancelled() || result.status === 'cancelled') { reject(new BoundedInflateError('cancelled')); return; }
      if (result.status === 'ok' && result.inspection !== undefined) { resolve(result.inspection); return; }
      if (result.status === 'not_epub') { reject(new EpubInspectionError('not_epub', '该文件未通过 EPUB 结构检查。')); return; }
      if (result.status === 'io_error' || result.status === 'ok') { reject(new Error('EPUB inspection I/O failed')); return; }
      reject(new EpubInputError(result.status));
    };
    try {
      const request: EpubWorkerRequest = { kind: 'inspect', root: root, xmlBytes: xmlBytes, limits: limits, entries: entries };
      thread.postMessage(request);
      unsubscribe = control.onCancel?.((): void => {
        const cancel: EpubWorkerCancel = { kind: 'cancel' };
        try { thread.postMessage(cancel); } catch (_) {}
      });
    } catch (_) { stop(); }
  });
}
