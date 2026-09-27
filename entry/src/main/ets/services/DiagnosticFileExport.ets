import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { closeFile, openFile, statFile, truncateFile, writeFile } from '../utils/FileIoBoundary';

export interface DiagnosticSaveSurface {
  choose(newFileName: string): Promise<string[]>;
}

export interface DiagnosticFileSurface {
  open(uri: string): Promise<number>;
  truncate(fd: number): Promise<void>;
  write(fd: number, bytes: Uint8Array, offset: number): Promise<number>;
  size(fd: number): Promise<number>;
  close(fd: number): void;
}

export type DiagnosticFileExportResult = 'saved' | 'cancelled';

export class DiagnosticFileExportError extends Error {
  readonly partialMayRemain: boolean;
  constructor(partialMayRemain: boolean) {
    super('Diagnostic file export failed');
    this.partialMayRemain = partialMayRemain;
  }
}

export class NativeDiagnosticSaveSurface implements DiagnosticSaveSurface {
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  choose(newFileName: string): Promise<string[]> {
    return new picker.DocumentViewPicker(this.context).save({
      newFileNames: [newFileName], fileSuffixChoices: ['JSON|.json']
    });
  }
}

export class NativeDiagnosticFileSurface implements DiagnosticFileSurface {
  async open(uri: string): Promise<number> {
    return (await openFile(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)).fd;
  }
  truncate(fd: number): Promise<void> { return truncateFile(fd, 0); }
  write(fd: number, bytes: Uint8Array, offset: number): Promise<number> {
    const remaining = bytes.slice(offset);
    return writeFile(fd, remaining.buffer as ArrayBuffer, { offset: offset, length: remaining.length });
  }
  async size(fd: number): Promise<number> { return (await statFile(fd)).size; }
  close(fd: number): void { closeFile(fd); }
}

export class DiagnosticFileExport {
  private saveSurface: DiagnosticSaveSurface;
  private fileSurface: DiagnosticFileSurface;
  constructor(saveSurface: DiagnosticSaveSurface, fileSurface: DiagnosticFileSurface) {
    this.saveSurface = saveSurface;
    this.fileSurface = fileSurface;
  }

  async save(bytes: Uint8Array): Promise<DiagnosticFileExportResult> {
    let destinationChosen = false;
    let fd: number | undefined;
    try {
      const uris = await this.saveSurface.choose('阅读器诊断信息.json');
      if (uris.length === 0) return 'cancelled';
      if (uris.length !== 1) throw new DiagnosticFileExportError(false);
      destinationChosen = true;
      fd = await this.fileSurface.open(uris[0]);
      await this.fileSurface.truncate(fd);
      let offset = 0;
      while (offset < bytes.length) {
        const count = await this.fileSurface.write(fd, bytes, offset);
        if (!Number.isSafeInteger(count) || count <= 0 || count > bytes.length - offset) {
          throw new DiagnosticFileExportError(true);
        }
        offset += count;
      }
      if (await this.fileSurface.size(fd) !== bytes.length) throw new DiagnosticFileExportError(true);
      return 'saved';
    } catch (error) {
      if (error instanceof DiagnosticFileExportError) throw error;
      throw new DiagnosticFileExportError(destinationChosen);
    } finally {
      if (fd !== undefined) {
        try { this.fileSurface.close(fd); } catch (_) {}
      }
    }
  }
}
