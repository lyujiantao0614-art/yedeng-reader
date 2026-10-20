import { Book } from '../domain/Models';
import { LibraryFolder, BookOrganization, SeriesContinuation, seriesContinuation, LibraryDeletionScope, libraryDeletionScope } from '../domain/LibraryOrganization';
import { LibraryRepository } from '../repositories/LibraryRepository';
import { createSecureUuid } from '../services/ManagedBookStore';

export interface LibraryDeletionContents { scope: LibraryDeletionScope; books: Book[]; }

export class LibraryOrganizationApplication {
  private queue: Promise<void> = Promise.resolve();
  private repository: LibraryRepository;
  constructor(repository: LibraryRepository) { this.repository = repository; }
  folders(): Promise<LibraryFolder[]> { return this.repository.listFolders(); }
  memberships(): Promise<BookOrganization[]> { return this.repository.listOrganizations(); }
  private serial(action: () => Promise<void>): Promise<void> {
    const task = this.queue.then(action);
    this.queue = task.catch((): void => {});
    return task;
  }
  private name(value: string): string {
    const result = value.trim();
    if (!result || result.length > 120 || /[\u0000-\u001F\u007F]/.test(result)) throw new Error('Invalid organization name');
    return result;
  }
  async create(name: string, parentId: string): Promise<void> {
    const folder: LibraryFolder = { folderId: createSecureUuid(), parentId, name: this.name(name) };
    return this.serial((): Promise<void> => this.repository.createFolder(folder));
  }
  rename(folderId: string, name: string): Promise<void> {
    const normalized = this.name(name);
    return this.serial((): Promise<void> => this.repository.renameFolder(folderId, normalized));
  }
  moveFolder(folderId: string, parentId: string): Promise<void> {
    return this.serial((): Promise<void> => this.repository.moveFolder(folderId, parentId));
  }
  remove(folderId: string, expectedIds?: string[]): Promise<void> {
    return this.serial((): Promise<void> => this.repository.deleteFolder(folderId, expectedIds));
  }
  async deletionContents(folderIds: string[], bookIds: string[]): Promise<LibraryDeletionContents> {
    const folders = await this.folders(), memberships = await this.memberships(), books = await this.repository.listBooks();
    const scope = libraryDeletionScope(folders, memberships, folderIds, bookIds);
    const selected = books.filter((book: Book): boolean => scope.bookIds.includes(book.bookId));
    if (selected.length !== scope.bookIds.length) throw new Error('Book unavailable');
    return { scope, books: selected };
  }
  moveBook(bookId: string, folderId: string): Promise<void> {
    return this.serial((): Promise<void> => this.repository.moveBook(bookId, folderId));
  }
  setSeries(bookId: string, name: string, order?: number): Promise<void> {
    const normalized = name.trim() ? this.name(name) : '';
    if (order !== undefined && (!normalized || !Number.isFinite(order) || order < 0 || order > 1000000)) throw new Error('Invalid volume order');
    return this.serial((): Promise<void> => this.repository.setSeries(bookId, normalized, normalized ? order : undefined));
  }
  async continuation(bookId: string): Promise<SeriesContinuation> {
    const values = await this.memberships();
    const current = values.find((item: BookOrganization): boolean => item.bookId === bookId);
    if (!current) throw new Error('Book unavailable');
    return seriesContinuation(current, values);
  }
}
