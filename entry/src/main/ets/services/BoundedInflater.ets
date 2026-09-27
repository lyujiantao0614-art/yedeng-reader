import { zlib } from '@kit.BasicServicesKit';

// These limits are supplied by the caller; this module sets no product budgets.
export interface InflateInput {
  read(maximumBytes: number): Promise<ArrayBuffer>;
}

export interface InflateOutput {
  write(bytes: ArrayBuffer): Promise<void>;
}

export interface InflateControl {
  isCancelled(): boolean;
  onCancel?(listener: () => void): () => void;
}

export type InflateFailure = 'cancelled' | 'resource_limit' | 'malformed' | 'io_error';

export class BoundedInflateError extends Error {
  code: InflateFailure;
  constructor(code: InflateFailure) {
    super(code);
    this.code = code;
  }
}

function checkCancellation(control: InflateControl): void {
  if (control.isCancelled()) throw new BoundedInflateError('cancelled');
}

async function endInflate(codec: zlib.Zip, stream: zlib.ZStream): Promise<void> {
  try { await codec.inflateEnd(stream); }
  catch (error) { throw error instanceof Error ? error : new Error('inflateEnd failed'); }
}

// Raw DEFLATE only. The ZIP reader owns metadata, CRC and path validation.
// Each call has at most a 64 KiB input and output buffer and a safe yield point.
export async function inflateBounded(input: InflateInput, output: InflateOutput,
  compressedBytes: number, maximumOutputBytes: number, control: InflateControl): Promise<number> {
  if (!Number.isSafeInteger(compressedBytes) || compressedBytes <= 0 ||
    !Number.isSafeInteger(maximumOutputBytes) || maximumOutputBytes < 0) {
    throw new BoundedInflateError('malformed');
  }
  checkCancellation(control);
  const codec = await zlib.createZip();
  let loaded = 0;
  let consumed = 0;
  let produced = 0;
  let chunk = new ArrayBuffer(0);
  let chunkOffset = 0;
  let initialized = false;
  let stream: zlib.ZStream = {};
  try {
    while (true) {
      checkCancellation(control);
      if (chunkOffset === chunk.byteLength && loaded < compressedBytes) {
        const requested = Math.min(65536, compressedBytes - loaded);
        try { chunk = await input.read(requested); }
        catch (_) { throw new BoundedInflateError('io_error'); }
        checkCancellation(control);
        if (chunk.byteLength === 0 || chunk.byteLength > requested) {
          throw new BoundedInflateError('malformed');
        }
        loaded += chunk.byteLength;
        chunkOffset = 0;
      }
      const remaining = chunk.byteLength - chunkOffset;
      // One extra byte detects overrun; it is never passed to the output sink.
      const capacity = Math.min(65536, maximumOutputBytes - produced + 1);
      const destination = new ArrayBuffer(capacity);
      stream = {
        nextIn: remaining > 0 ? chunk.slice(chunkOffset) : new ArrayBuffer(1),
        availableIn: remaining,
        nextOut: destination,
        availableOut: capacity
      };
      if (!initialized) {
        const init = await codec.inflateInit2(stream, -15);
        if (init !== zlib.ReturnStatus.OK) throw new BoundedInflateError('malformed');
        initialized = true;
      }
      const status = await codec.inflate(stream, zlib.CompressFlushMode.NO_FLUSH);
      const counters = await codec.getZStream();
      checkCancellation(control);
      const nextConsumed = counters.totalIn ?? -1;
      const nextProduced = counters.totalOut ?? -1;
      const inputDelta = nextConsumed - consumed;
      const count = nextProduced - produced;
      if (inputDelta < 0 || inputDelta > remaining || count < 0 || count > capacity ||
        (inputDelta === 0 && count === 0 && status !== zlib.ReturnStatus.STREAM_END)) {
        throw new BoundedInflateError('malformed');
      }
      if (nextProduced > maximumOutputBytes) throw new BoundedInflateError('resource_limit');
      chunkOffset += inputDelta;
      consumed = nextConsumed;
      produced = nextProduced;
      if (count > 0) {
        try { await output.write(destination.slice(0, count)); }
        catch (_) { throw new BoundedInflateError('io_error'); }
      }
      checkCancellation(control);
      if (status === zlib.ReturnStatus.STREAM_END) {
        if (consumed !== compressedBytes) throw new BoundedInflateError('malformed');
        return produced;
      }
      if (status !== zlib.ReturnStatus.OK) throw new BoundedInflateError('malformed');
    }
  } catch (error) {
    if (error instanceof BoundedInflateError) throw error;
    throw new BoundedInflateError('malformed');
  } finally {
    if (initialized) await endInflate(codec, stream);
  }
}
