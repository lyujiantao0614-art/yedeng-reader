import { common } from '@kit.AbilityKit';
import { Book, LibraryOperation, ReconciliationReport } from '../domain/Models';
import { LibraryRepository } from '../repositories/LibraryRepository';
import { EncryptedBookmarkStore } from '../repositories/EncryptedBookmarkStore';
import { BookDeletionService } from './BookDeletionService';
import { ManagedBookStore } from './ManagedBookStore';

function emptyReport(): ReconciliationReport {
  return {
    resumedDeletes: 0,
    rolledBackImports: 0,
    rolledBackRepairs: 0,
    removedStagingEntries: 0,
    markedMissingSources: 0,
    restoredAvailableSources: 0,
    clearedMissingCovers: 0,
    quarantinedOrphans: 0,
    retainedQuarantinedOrphans: 0
  };
}

export class LibraryReconciliationService {
  private repository: LibraryRepository;
  private managedStore: ManagedBookStore;
  private deletionService: BookDeletionService;

  constructor(context: common.Context, repository: LibraryRepository,
    managedStore?: ManagedBookStore, encrypted?: EncryptedBookmarkStore) {
    this.repository = repository;
    this.managedStore = managedStore ?? new ManagedBookStore(context);
    this.deletionService = new BookDeletionService(context, repository, this.managedStore, encrypted);
  }

  async reconcile(): Promise<ReconciliationReport> {
    await this.managedStore.initialize();
    const report = emptyReport();
    const operations = await this.repository.listOperations();

    for (const operation of operations) {
      if (operation.kind !== 'delete') continue;
      try {
        await this.deletionService.continueDelete(operation);
        report.resumedDeletes += 1;
      } catch (_) {
      }
    }

    const remaining = await this.repository.listOperations();
    for (const operation of remaining) {
      if (operation.kind === 'delete') continue;
      const rolledBack = await this.rollbackPrepared(operation);
      if (!rolledBack) continue;
      if (operation.kind === 'import') report.rolledBackImports += 1;
      else report.rolledBackRepairs += 1;
    }

    try {
      report.removedStagingEntries = await this.managedStore.cleanupAllStaging();
    } catch (_) {
    }

    const books = await this.repository.listBooks();
    for (const book of books) {
      const sourceExists = await this.managedStore.hasBookFile(book.bookId);
      if (!sourceExists && book.sourceState !== 'missing') {
        await this.repository.markSourceState(book.bookId, 'missing');
        report.markedMissingSources += 1;
      } else if (sourceExists && book.sourceState !== 'available') {
        await this.repository.markSourceState(book.bookId, 'available');
        report.restoredAvailableSources += 1;
      }
      if (book.coverRelativePath !== undefined &&
        !await this.managedStore.hasManagedRelativePath(book.bookId, book.coverRelativePath)) {
        await this.repository.clearCoverRelativePath(book.bookId);
        report.clearedMissingCovers += 1;
      }
    }

    const knownBookIds = new Set<string>();
    for (const book of books) knownBookIds.add(book.bookId);
    const operationBookIds = new Set<string>();
    const activeOperations = await this.repository.listOperations();
    for (const operation of activeOperations) operationBookIds.add(operation.bookId);
    const managedIds = await this.managedStore.listManagedBookIds();
    for (const bookId of managedIds) {
      if (knownBookIds.has(bookId) || operationBookIds.has(bookId)) continue;
      try {
        await this.managedStore.quarantineOrphan(bookId);
        report.quarantinedOrphans += 1;
      } catch (_) {
      }
    }
    report.retainedQuarantinedOrphans = await this.managedStore.countQuarantinedOrphans();
    return report;
  }

  async cleanupQuarantinedOrphans(): Promise<number> {
    return this.managedStore.cleanupQuarantinedOrphans();
  }

  private async rollbackPrepared(operation: LibraryOperation): Promise<boolean> {
    try {
      await this.managedStore.deleteFinal(operation.bookId);
      if (operation.stagingToken !== undefined) await this.managedStore.deleteStage(operation.stagingToken);
      await this.repository.deleteOperation(operation.operationId);
      return true;
    } catch (_) {
      return false;
    }
  }
}
