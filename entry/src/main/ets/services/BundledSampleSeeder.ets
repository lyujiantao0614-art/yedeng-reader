import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { createSecureUuid } from './ManagedBookStore';
import { ImportResult } from './BookImportService';

export type SampleSeedOutcome = 'added' | 'already-present' | 'skipped-existing-library' | 'done';

const SAMPLE_RESOURCE: string = 'demo/under-the-lamp.epub';
const MAX_SAMPLE_BYTES: number = 256 * 1024;

// A durable one-time flag prevents a user-deleted sample from returning after
// an app upgrade. The ordinary bounded importer still owns file validation,
// identity, and the transactional library commit.
export async function seedBundledSample(context: common.UIAbilityContext,
  hasBooks: () => Promise<boolean>, importSample: (uri: string) => Promise<ImportResult>): Promise<SampleSeedOutcome> {
  const store = preferences.getPreferencesSync(context, { name: 'bundled_sample' });
  if (store.getSync('seeded_v1', false) === true) return 'done';
  if (await hasBooks()) {
    store.putSync('seeded_v1', true);
    store.flushSync();
    return 'skipped-existing-library';
  }

  const bytes = await context.resourceManager.getRawFileContent(SAMPLE_RESOURCE);
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_SAMPLE_BYTES) {
    throw new Error('Bundled sample size is invalid');
  }
  const path = `${context.cacheDir}/bundled-sample-${createSecureUuid()}.epub`;
  let file: fs.File | undefined;
  try {
    file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    let offset = 0;
    while (offset < bytes.byteLength) {
      const remaining = bytes.buffer.slice(bytes.byteOffset + offset,
        bytes.byteOffset + bytes.byteLength);
      const written = await fs.write(file.fd, remaining, { offset: offset, length: bytes.byteLength - offset });
      if (written <= 0) throw new Error('Bundled sample write failed');
      offset += written;
    }
    fs.closeSync(file);
    file = undefined;
    const result = await importSample(path);
    if (result.status !== 'prepared-new' && result.status !== 'prepared-repair' && result.status !== 'duplicate') {
      throw new Error('Bundled sample import failed');
    }
    store.putSync('seeded_v1', true);
    store.flushSync();
    return result.status === 'duplicate' ? 'already-present' : 'added';
  } finally {
    if (file !== undefined) fs.closeSync(file);
    try { await fs.unlink(path); } catch (_) { /* A missing temporary file needs no cleanup. */ }
  }
}
