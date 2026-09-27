import { statfs } from '@kit.CoreFileKit';
import { BoundedInflateError } from './BoundedInflater';

export type ImportWriteStage = 'source-copy' | 'extraction' | 'final-epub' | 'final-cover';
export interface ImportWriteGuard {
  beforeWrite(bytes: number, stage: ImportWriteStage): Promise<void>;
}
export interface ImportFreeSpace {
  availableBytes(path: string): Promise<number>;
}
class LocalFreeSpace implements ImportFreeSpace {
  async availableBytes(path: string): Promise<number> {
    try { return await statfs.getFreeSize(path); }
    catch (error) { throw error instanceof Error ? error : new Error('getFreeSize failed'); }
  }
}

// One filesystem query per bounded write, including final copies. A concurrent
// external writer may still consume space; ordinary I/O errors use rollback.
export class ImportStorageBudget implements ImportWriteGuard {
  private path: string;
  private reserve: number;
  private probe: ImportFreeSpace;
  constructor(path: string, reserveBytes: number, probe: ImportFreeSpace = new LocalFreeSpace()) {
    this.path = path; this.reserve = reserveBytes; this.probe = probe;
  }
  async beforeWrite(bytes: number): Promise<void> {
    if (!Number.isSafeInteger(this.reserve) || this.reserve < 0 ||
      !Number.isSafeInteger(bytes) || bytes < 0) throw new BoundedInflateError('resource_limit');
    const available = await this.probe.availableBytes(this.path);
    if (!Number.isSafeInteger(available) || available < 0 || available - bytes < this.reserve) {
      throw new BoundedInflateError('io_error');
    }
  }
}
