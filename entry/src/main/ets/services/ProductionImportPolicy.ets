import { BoundedImportPolicy } from './BookImportService';
import { ImportCancellation } from './ImportCancellation';

// Owner-accepted development limits from the Milestone 3.4 P2 gate.
// Revalidate these provisional values across the final P4 device matrix.
export const VISIBLE_IMPORT_BATCH_LIMIT: number = 4;
export const IMPORT_VALIDATION_VERSION: number = 1;

export function createProductionImportPolicy(): BoundedImportPolicy {
  return {
    validationVersion: IMPORT_VALIDATION_VERSION,
    zip: {
      archiveBytes: 67108864,
      expandedBytes: 268435456,
      entryBytes: 16777216,
      entryCount: 4096,
      pathCharacters: 1024,
      compressionRatio: 1000
    },
    xmlBytes: 2097152,
    resources: {
      sectionBytes: 2097152,
      xmlDepth: 128,
      xmlElements: 100000,
      imageBytes: 8388608,
      imageDimension: 4096,
      imagePixels: 16777216,
      imageFrames: 8,
      fontBytes: 8388608,
      fontExpandedBytes: 8388608
    },
    reserveBytes: 536870912,
    control: new ImportCancellation()
  };
}
