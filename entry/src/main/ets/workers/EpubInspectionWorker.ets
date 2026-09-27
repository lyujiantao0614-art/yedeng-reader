import { worker, MessageEvents } from '@kit.ArkTS';
import { EpubInspector, EpubInspectionError } from '../services/EpubInspector';
import { EpubWorkerMessage, EpubWorkerRequest, EpubWorkerResult } from '../services/EpubInspectionWorkerClient';
import { EpubInputError } from '../services/EpubInputPolicy';
import { BoundedInflateError } from '../services/BoundedInflater';
import { ImportCancellation } from '../services/ImportCancellation';

const port = worker.workerPort;
const control = new ImportCancellation();
let started = false;

function postResult(result: EpubWorkerResult): void {
  try { port.postMessage(result); }
  catch (error) { throw error instanceof Error ? error : new Error('postMessage failed'); }
}

function closePort(): void {
  try { port.close(); }
  catch (error) { throw error instanceof Error ? error : new Error('workerPort close failed'); }
}

async function inspect(request: EpubWorkerRequest): Promise<void> {
  let result: EpubWorkerResult = { status: 'io_error' };
  try {
    if (control.isCancelled()) throw new BoundedInflateError('cancelled');
    const inspection = await new EpubInspector().inspect(request.root, request.xmlBytes,
      { limits: request.limits, entries: request.entries, control: control });
    result = { status: control.isCancelled() ? 'cancelled' : 'ok', inspection: inspection };
  } catch (error) {
    if (error instanceof EpubInputError) result = { status: error.code };
    else if (error instanceof BoundedInflateError) result = { status: error.code };
    else if (error instanceof EpubInspectionError) {
      result = { status: error.code === 'not_epub' ? 'not_epub' : error.code === 'encrypted' ? 'encrypted' : 'malformed' };
    }
  } finally {
    try { postResult(result); } finally { closePort(); }
  }
}
port.onmessage = (event: MessageEvents): void => {
  const message = event.data as EpubWorkerMessage;
  if (message.kind === 'cancel') { control.cancelled = true; return; }
  if (started) return;
  started = true;
  inspect(message).catch((): void => { try { closePort(); } catch (_) {} });
};
