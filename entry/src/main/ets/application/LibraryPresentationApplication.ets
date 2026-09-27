import { BookshelfDefaultMode, BookshelfTheme, LibraryViewMode } from '../domain/LibraryPresentation';
import { LibraryPresentationRepository } from '../repositories/LibraryPresentationRepository';

export class LibraryPresentationApplication {
  private repository: LibraryPresentationRepository;

  constructor(repository: LibraryPresentationRepository) {
    this.repository = repository;
  }

  loadViewMode(): LibraryViewMode {
    return this.repository.loadViewMode();
  }

  saveViewMode(mode: LibraryViewMode): void {
    this.repository.saveViewMode(mode);
  }

  loadTheme(): BookshelfTheme {
    return this.repository.loadTheme();
  }

  loadDefaultMode(): BookshelfDefaultMode {
    return this.repository.loadDefaultMode();
  }

  saveAppearance(theme: BookshelfTheme, mode: BookshelfDefaultMode): void {
    this.repository.saveAppearance(theme, mode);
  }
}
