import { common } from '@kit.AbilityKit';
import { Book, LibraryOperation } from '../domain/Models';
import { LibraryRepository } from '../repositories/LibraryRepository';
import { EncryptedBookmarkStore } from '../repositories/EncryptedBookmarkStore';
import { createSecureUuid, ManagedBookStore } from './ManagedBookStore';

export class BookDeletionService {
  private repository: LibraryRepository;
  private managedStore: ManagedBookStore;
  private encrypted?: EncryptedBookmarkStore;

  constructor(context: common.Context, repository: LibraryRepository,
    managedStore?: ManagedBookStore, encrypted?: EncryptedBookmarkStore) {
    this.repository = repository;
    this.managedStore = managedStore ?? new ManagedBookStore(context);
    this.encrypted = encrypted;
  }

  async delete(book: Book): Promise<void> {
    const pending = (await this.repository.listOperations()).find((operation: LibraryOperation): boolean =>
      operation.bookId === book.bookId);
    if (pending !== undefined) {
      if (pending.kind !== 'delete') throw new Error('Book has another pending operation');
      await this.continueDelete(pending);
      return;
    }
    const now = Date.now();
    const operation: LibraryOperation = {
      operationId: createSecureUuid(),
      kind: 'delete',
      state: 'requested',
      bookId: book.bookId,
      createdAt: now,
      updatedAt: now
    };
    await this.repository.createOperation(operation);
    await this.continueDelete(operation);
  }

  async continueDelete(operation: LibraryOperation): Promise<void> {
    if (operation.kind !== 'delete') throw new Error('Not a delete operation');
    const targetAuthority = await this.repository.bookmarkAuthority() === 'target' ||
      await this.repository.textRecordsEnabled();
    if (targetAuthority) this.requireEncrypted().ensureAvailable();
    if (operation.state === 'requested') {
      await this.managedStore.deleteFinal(operation.bookId);
      await this.repository.updateOperationState(operation.operationId, 'files_removed', Date.now());
    }
    if (targetAuthority) await this.requireEncrypted().deleteBook(operation.bookId);
    await this.repository.completeDelete(operation.operationId, operation.bookId);
  }

  private requireEncrypted(): EncryptedBookmarkStore {
    if (this.encrypted === undefined) throw new Error('Authoritative record store unavailable');
    return this.encrypted;
  }
}
