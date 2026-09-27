import {
  DiagnosticMetadata,
  DiagnosticSnapshotSource,
  encodeDiagnosticSnapshot
} from '../diagnostics/DiagnosticExportContract';
import { DiagnosticFileExport, DiagnosticFileExportError } from '../services/DiagnosticFileExport';

export interface DiagnosticMetadataProvider {
  metadata(): DiagnosticMetadata;
}

export type DiagnosticExportStatus = 'saved' | 'cancelled' | 'failed' | 'failed-partial-possible';

export interface DiagnosticExportAction {
  export(): Promise<DiagnosticExportStatus>;
}

export class DiagnosticExportApplication implements DiagnosticExportAction {
  private source: DiagnosticSnapshotSource;
  private metadataProvider: DiagnosticMetadataProvider;
  private destination: DiagnosticFileExport;
  constructor(source: DiagnosticSnapshotSource, metadataProvider: DiagnosticMetadataProvider,
    destination: DiagnosticFileExport) {
    this.source = source;
    this.metadataProvider = metadataProvider;
    this.destination = destination;
  }

  async export(): Promise<DiagnosticExportStatus> {
    const bytes = encodeDiagnosticSnapshot(this.metadataProvider.metadata(), this.source.exportSnapshot());
    try {
      return await this.destination.save(bytes);
    } catch (error) {
      return error instanceof DiagnosticFileExportError && error.partialMayRemain ?
        'failed-partial-possible' : 'failed';
    } finally {
      bytes.fill(0);
      this.source.clearExportSnapshot();
    }
  }
}
