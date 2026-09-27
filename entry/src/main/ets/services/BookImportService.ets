import { inspectEpubInWorker } from './EpubInspectionWorkerClient';
import { ImportMeasurementObserver, measureImportStage } from './ImportMeasurement';
import { ImportStorageBudget, ImportWriteGuard } from './ImportStorageBudget';
import { EpubResourceLimits, validateResourceLimits } from './EpubResourceInspector';
import { BoundedInflateError, InflateControl } from './BoundedInflater';
import { EpubInputError } from './EpubInputPolicy';
import { FileZipSource, extractBoundedZip } from './BoundedZipExtractor';
import { ZipLimits, ZipEntry, validateZipLimits } from './EpubZipIndex';
import { common } from '@kit.AbilityKit';
import { zlib } from '@kit.BasicServicesKit';
import { Book, LibraryOperation, LibraryOperationKind } from '../domain/Models';
import { LibraryRepository } from '../repositories/LibraryRepository';
import { ensureDirectory } from '../utils/FileUtils';
import { EpubInspection, EpubInspectionError, EpubInspector } from './EpubInspector';
import { createSecureUuid, ManagedBookStore } from './ManagedBookStore';
import { convertTxtToEpub, previewTxt } from './TxtToEpub';
import { TxtEncodingChoice, TxtPreview } from '../domain/TxtEncoding';

export type ImportStatus = 'prepared-new' | 'prepared-repair' | 'duplicate' |
  'cancelled' | 'not_epub' | 'malformed' | 'encrypted' | 'io_error' | 'resource_limit' | 'unsupported_encoding' | 'cleanup_pending' | 'unsupported_resource';

export interface ManagedBookValidation {
  status: 'valid' | 'resource_limit' | 'unsupported_encoding' | 'unsupported_resource' |
    'malformed' | 'encrypted' | 'io_error' | 'cleanup_pending' | 'cancelled';
  message?: string;
}

export interface BoundedImportPolicy {
  validationVersion: number;
  zip: ZipLimits;
  xmlBytes: number;
  resources: EpubResourceLimits;
  reserveBytes: number;
  storage?: ImportWriteGuard;
  observer?: ImportMeasurementObserver;
  control: InflateControl;
}

export function validateImportPolicy(policy: BoundedImportPolicy): void {
  validateZipLimits(policy.zip);
  validateResourceLimits(policy.resources);
  if (!Number.isSafeInteger(policy.validationVersion) || policy.validationVersion <= 0 ||
    !Number.isSafeInteger(policy.xmlBytes) || policy.xmlBytes <= 0 ||
    !Number.isSafeInteger(policy.reserveBytes) || policy.reserveBytes < 0) {
    throw new EpubInputError('resource_limit');
  }
}

export function importPolicyValidationKey(policy: BoundedImportPolicy): string {
  validateImportPolicy(policy);
  return [policy.validationVersion,
    policy.zip.archiveBytes, policy.zip.expandedBytes, policy.zip.entryBytes,
    policy.zip.entryCount, policy.zip.pathCharacters, policy.zip.compressionRatio,
    policy.xmlBytes, policy.resources.sectionBytes, policy.resources.xmlDepth,
    policy.resources.xmlElements, policy.resources.imageBytes, policy.resources.imageDimension,
    policy.resources.imagePixels, policy.resources.imageFrames, policy.resources.fontBytes,
    policy.resources.fontExpandedBytes].join('|');
}

export interface ImportResult {
  status: ImportStatus;
  book?: Book;
  operationId?: string;
  operationKind?: LibraryOperationKind;
  message?: string;
}

export function bytesToHex(bytes: Uint8Array): string {
  let output = '';
  for (const value of bytes) output += value.toString(16).padStart(2, '0');
  return output;
}

export function resolveDisplayTitle(epubTitle: string | undefined, sourceName: string): string {
  const title = epubTitle?.trim() ?? '';
  return title.length > 0 ? title : sourceName;
}

export function classifyInspectionError(error: EpubInspectionError): ImportStatus {
  if (error.code === 'encrypted') return 'encrypted';
  if (error.code === 'not_epub') return 'not_epub';
  return 'malformed';
}

export function isMatchingRepairIdentity(expectedBookId: string, actualHash: string): boolean {
  return expectedBookId === actualHash;
}

function sourceFileName(uri: string): string {
  const normalized = uri.replace(/\\/g, '/');
  const encoded = normalized.substring(normalized.lastIndexOf('/') + 1).split('?')[0];
  try {
    return decodeURIComponent(encoded);
  } catch (_) {
    return encoded;
  }
}

function coverExtension(path: string): string {
  const match = /\.([a-zA-Z0-9]{1,8})$/.exec(path);
  return match === null ? 'img' : match[1].toLowerCase();
}

export class BookImportService {
  private repository: LibraryRepository;
  private managedStore: ManagedBookStore;
  private inspector: EpubInspector = new EpubInspector();
  private policy?: BoundedImportPolicy;
  private storage?: ImportWriteGuard;

  constructor(context: common.Context, repository: LibraryRepository,
    managedStore?: ManagedBookStore, policy?: BoundedImportPolicy) {
    this.repository = repository;
    this.policy = policy;
    this.storage = policy === undefined ? undefined : policy.storage ?? new ImportStorageBudget(context.filesDir, policy.reserveBytes);
    this.managedStore = managedStore ?? new ManagedBookStore(context);
  }

  async initializeStorage(): Promise<void> {
    await this.managedStore.initialize();
  }

  async import(uri?: string, control?: InflateControl, txtEncoding: TxtEncodingChoice = 'auto'): Promise<ImportResult> {
    return this.prepare(uri, undefined, control, undefined, txtEncoding);
  }

  previewText(uri: string, encoding: TxtEncodingChoice): Promise<TxtPreview> {
    return previewTxt(uri, encoding);
  }

  async repair(book: Book, uri?: string, control?: InflateControl): Promise<ImportResult> {
    return this.prepare(uri, book, control);
  }

  private async prepare(uri: string | undefined, expectedRepair: Book | undefined,
    control?: InflateControl, textSourceName?: string,
    txtEncoding: TxtEncodingChoice = 'auto'): Promise<ImportResult> {
    if (uri === undefined || uri.length === 0) return { status: 'cancelled' };
    const name = sourceFileName(uri);
    if (name.toLowerCase().endsWith('.txt') && textSourceName === undefined) {
      return this.prepareText(uri, name, expectedRepair, control, txtEncoding);
    }
    if (!name.toLowerCase().endsWith('.epub')) {
      return { status: 'not_epub', message: '请选择 .epub 或 .txt 文件。' };
    }

    const stagingToken = this.managedStore.createToken();
    const operationControl = control ?? this.policy?.control;
    let operation: LibraryOperation | undefined;
    try {
      if (this.policy !== undefined) validateImportPolicy(this.policy);
      await this.managedStore.createStage(stagingToken);
      const hash = await measureImportStage(this.policy?.observer, 'copy_hash', (): Promise<string> =>
        this.managedStore.stageAndHash(stagingToken, uri, this.policy?.zip.archiveBytes, operationControl, this.storage));
      if (expectedRepair !== undefined && !isMatchingRepairIdentity(expectedRepair.bookId, hash)) {
        await this.managedStore.deleteStage(stagingToken);
        return { status: 'malformed', message: '所选文件与原书不是同一内容，原阅读进度未改变。' };
      }

      const existing = await this.repository.getBook(hash);
      if (existing !== undefined && expectedRepair === undefined &&
        existing.sourceState === 'available' && await this.managedStore.hasBookFile(hash)) {
        await this.managedStore.deleteStage(stagingToken);
        return { status: 'duplicate', book: existing };
      }
      if (expectedRepair !== undefined && existing?.bookId !== expectedRepair.bookId) {
        await this.managedStore.deleteStage(stagingToken);
        return { status: 'malformed', message: '找不到与原记录匹配的书籍，原阅读进度未改变。' };
      }

      const extractedRoot = this.managedStore.extractedPath(stagingToken);
      let entries: ZipEntry[] = [];
      if (this.policy !== undefined) {
        const boundedControl = control ?? this.policy.control;
        const source = await FileZipSource.open(this.managedStore.stagedEpubPath(stagingToken));
        try { entries = await extractBoundedZip(source, extractedRoot, this.policy.zip, boundedControl, this.storage, this.policy.observer); }
        finally { source.close(); }
      } else {
        await ensureDirectory(extractedRoot);
        try {
          await zlib.decompressFile(this.managedStore.stagedEpubPath(stagingToken), extractedRoot);
        } catch (_) {
          throw new EpubInspectionError('not_epub', 'The selected file is not a readable EPUB archive');
        }
      }
      const inspection = await measureImportStage(this.policy?.observer, 'xml_resources', (): Promise<EpubInspection> =>
        this.policy === undefined ? this.inspector.inspect(extractedRoot) :
          inspectEpubInWorker(extractedRoot, this.policy.xmlBytes, this.policy.resources, entries,
            control ?? this.policy.control));
      if (operationControl?.isCancelled()) throw new BoundedInflateError('cancelled');
      const repairBook = expectedRepair ?? (existing?.sourceState === 'missing' ? existing : undefined);
      const kind: LibraryOperationKind = repairBook === undefined ? 'import' : 'repair';
      const now = Date.now();
      operation = {
        operationId: createSecureUuid(),
        kind: kind,
        state: 'preparing',
        bookId: hash,
        stagingToken: stagingToken,
        createdAt: now,
        updatedAt: now
      };
      await this.repository.createOperation(operation);

      if (repairBook !== undefined) {
        await this.managedStore.deleteFinal(hash);
      }
      const managed = await this.managedStore.prepareFinal(
        stagingToken,
        hash,
        inspection.coverAbsolutePath,
        inspection.coverAbsolutePath === undefined ? undefined : coverExtension(inspection.coverAbsolutePath),
        this.storage, this.policy?.observer,
        this.policy === undefined ? undefined : importPolicyValidationKey(this.policy));
      if (operationControl?.isCancelled()) throw new BoundedInflateError('cancelled');
      await this.repository.updateOperationState(operation.operationId, 'prepared', Date.now());
      await measureImportStage(this.policy?.observer, 'cleanup', (): Promise<void> => this.managedStore.deleteStage(stagingToken));
      if (operationControl?.isCancelled()) throw new BoundedInflateError('cancelled');

      const book: Book = repairBook === undefined ? {
        bookId: hash,
        fileHash: hash,
        title: textSourceName === undefined ? resolveDisplayTitle(inspection.title, name) :
          textSourceName.replace(/\.txt$/i, ''),
        author: inspection.author,
        epubRelativePath: managed.epubRelativePath,
        coverRelativePath: managed.coverRelativePath,
        importedAt: now,
        sourceState: 'available'
      } : {
        bookId: repairBook.bookId,
        fileHash: repairBook.fileHash,
        title: repairBook.title,
        author: repairBook.author,
        epubRelativePath: managed.epubRelativePath,
        coverRelativePath: managed.coverRelativePath,
        importedAt: repairBook.importedAt,
        lastOpenedAt: repairBook.lastOpenedAt,
        sourceState: 'missing'
      };
      return {
        status: kind === 'import' ? 'prepared-new' : 'prepared-repair',
        book: book,
        operationId: operation.operationId,
        operationKind: kind
      };
    } catch (error) {
      let cleanupPending = false;
      if (operation !== undefined) {
        try {
          cleanupPending = !await this.rollbackPrepared(operation.operationId, operation.bookId, stagingToken);
        } catch (_) {
          cleanupPending = true; // Keep the durable operation for startup reconciliation.
        }
      } else {
        try {
          await this.managedStore.deleteStage(stagingToken);
        } catch (_) {
          cleanupPending = true;
        }
      }
      if (cleanupPending) {
        return { status: 'cleanup_pending', message: '导入未完成，临时文件清理待重试；原有书籍和进度保留。' };
      }
      if (error instanceof EpubInputError || error instanceof BoundedInflateError) {
        const code = error.code;
        const message = code === 'resource_limit' ? '这本书超过当前安全资源限制，未导入。' :
          code === 'unsupported_encoding' ? '这本书的文字编码不受支持或声明不一致，未导入。' :
          code === 'unsupported_resource' ? '这本书包含当前安全检查不支持的资源，未导入。' :
          code === 'cancelled' ? '已取消导入。' : '无法导入这本书，原有书籍和进度未改变。';
        return { status: code, message: message };
      }
      if (error instanceof EpubInspectionError) {
        return { status: classifyInspectionError(error), message: error.message };
      }
      return { status: 'io_error', message: '导入失败，请确认文件仍可访问且设备空间充足。' };
    }
  }

  private async prepareText(uri: string, name: string, expectedRepair: Book | undefined,
    control?: InflateControl, txtEncoding: TxtEncodingChoice = 'auto'): Promise<ImportResult> {
    const token = this.managedStore.createToken();
    let stageCreated = false;
    let result: ImportResult;
    try {
      await this.managedStore.createStage(token);
      stageCreated = true;
      await convertTxtToEpub(uri, this.managedStore.stagedEpubPath(token),
        control ?? this.policy?.control, this.storage, txtEncoding);
      result = await this.prepare(this.managedStore.stagedEpubPath(token), expectedRepair, control, name);
    } catch (error) {
      if (error instanceof EpubInputError) {
        result = { status: error.code, message: error.code === 'resource_limit' ?
          'TXT 超过 8 MiB 或转换后的安全上限，未导入。' :
          error.code === 'unsupported_encoding' ? '无法按所选编码读取 TXT，请预览并选择编码。' :
            'TXT 没有可阅读的正文，未导入。' };
      } else if (error instanceof BoundedInflateError && error.code === 'cancelled') {
        result = { status: 'cancelled', message: '已取消导入。' };
      } else {
        result = { status: 'io_error', message: 'TXT 读取或转换失败，请重试。' };
      }
    }
    if (stageCreated) {
      try { await this.managedStore.deleteStage(token); }
      catch (_) { return { status: 'cleanup_pending', message: 'TXT 临时文件待清理，请重试。' }; }
    }
    return result;
  }

  // Imported bytes are immutable in app-private storage. A matching policy
  // marker avoids repeating full extraction on every open; legacy books and
  // policy changes take the bounded revalidation path once.
  async validateManaged(bookId: string, control?: InflateControl): Promise<ManagedBookValidation> {
    if (this.policy === undefined) return { status: 'valid' };
    const policy = this.policy;
    const checkControl = control ?? policy.control;
    const token = this.managedStore.createToken();
    let validationKey = '';
    let stageCreated = false;
    let result: ManagedBookValidation = { status: 'valid' };
    try {
      validateImportPolicy(policy);
      validationKey = importPolicyValidationKey(policy);
      if (await this.managedStore.hasCurrentValidation(bookId, validationKey)) return result;
      await this.managedStore.createStage(token);
      stageCreated = true;
      const archive = await FileZipSource.open(this.managedStore.bookFilePath(bookId));
      try {
        const root = this.managedStore.extractedPath(token);
        const entries = await extractBoundedZip(archive, root, policy.zip, checkControl, this.storage);
        await inspectEpubInWorker(root, policy.xmlBytes, policy.resources, entries, checkControl);
      } finally { archive.close(); }
    } catch (error) {
      if (error instanceof EpubInputError || error instanceof BoundedInflateError) {
        result = { status: error.code, message: error.code === 'resource_limit' ?
          '这本书超过当前安全资源限制，未打开；原文件和阅读进度保留。' :
          error.code === 'unsupported_encoding' ? '这本书的编码不受支持，原文件和阅读进度保留。' :
          error.code === 'unsupported_resource' ? '这本书包含当前安全检查不支持的资源，原文件和阅读进度保留。' :
          '这本书未通过打开前检查，原文件和阅读进度保留。' };
      } else if (error instanceof EpubInspectionError) {
        result = { status: error.code === 'encrypted' ? 'encrypted' : 'malformed',
          message: '这本书未通过结构检查，原文件和阅读进度保留。' };
      } else {
        result = { status: 'io_error', message: '打开前检查失败，请确认存储空间可用；原文件和阅读进度保留。' };
      }
    } finally {
      if (stageCreated) {
        try { await this.managedStore.deleteStage(token); }
        catch (_) { result = { status: 'cleanup_pending', message: '检查临时文件待清理，请重试；原文件和阅读进度保留。' }; }
      }
    }
    if (result.status === 'valid' && validationKey.length > 0) {
      try { await this.managedStore.markValidationCurrent(bookId, validationKey); }
      catch (_) {
        // Validation succeeded. A cache write failure must not block reading;
        // the next open safely retries the bounded validation.
      }
    }
    return result;
  }

  async commitPrepared(operationId: string, kind: LibraryOperationKind, book: Book): Promise<void> {
    if (kind === 'import') {
      await measureImportStage(this.policy?.observer, 'commit', (): Promise<void> => this.repository.commitPreparedImport(operationId, book));
    } else if (kind === 'repair') {
      await measureImportStage(this.policy?.observer, 'commit', (): Promise<void> => this.repository.commitPreparedRepair(operationId, book.bookId));
    } else {
      throw new Error('Delete operation cannot be committed as an import');
    }
  }

  async rollbackPrepared(operationId: string, bookId: string, stagingToken?: string): Promise<boolean> {
    let fileFailure = false;
    try {
      await this.managedStore.deleteFinal(bookId);
    } catch (_) {
      fileFailure = true;
    }
    if (stagingToken !== undefined) {
      try {
        await this.managedStore.deleteStage(stagingToken);
      } catch (_) {
        fileFailure = true;
      }
    }
    if (!fileFailure) await this.repository.deleteOperation(operationId);
    return !fileFailure;
  }
}
