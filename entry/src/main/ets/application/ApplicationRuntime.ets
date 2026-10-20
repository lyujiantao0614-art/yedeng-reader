import { common } from '@kit.AbilityKit';
import { BundledDictionaryProvider } from '../dictionary/BundledDictionaryProvider';
import { DictionaryService } from '../dictionary/DictionaryService';
import { ReconciliationReport } from '../domain/Models';
import { LibraryRepository } from '../repositories/LibraryRepository';
import { EncryptedBookmarkStore } from '../repositories/EncryptedBookmarkStore';
import { ReaderSettingsRepository } from '../repositories/ReaderSettingsRepository';
import { LibraryPresentationRepository } from '../repositories/LibraryPresentationRepository';
import { BookDeletionService } from '../services/BookDeletionService';
import { BookImportService } from '../services/BookImportService';
import { LibraryReconciliationService } from '../services/LibraryReconciliationService';
import { ManagedBookStore } from '../services/ManagedBookStore';
import { createProductionImportPolicy } from '../services/ProductionImportPolicy';
import { readerSessionService, ReaderSessionService } from '../services/ReaderSessionService';
import { BookmarkApplication } from './BookmarkApplication';
import { TextMarkApplication } from './TextMarkApplication';
import { LibraryOrganizationApplication } from './LibraryOrganizationApplication';
import { DiagnosticExportApplication } from './DiagnosticExportApplication';
import { LibraryApplication } from './LibraryApplication';
import { LibraryPresentationApplication } from './LibraryPresentationApplication';
import { ReaderAppearanceApplication } from './ReaderAppearanceApplication';
import { systemColorModeLifecycle } from '../reader/SystemColorModeLifecycle';
import { readerOpenDiagnostics } from '../diagnostics/ReaderOpenDiagnostics';
import {
  DiagnosticFileExport,
  NativeDiagnosticFileSurface,
  NativeDiagnosticSaveSurface
} from '../services/DiagnosticFileExport';
import { PlatformDiagnosticMetadata } from '../services/PlatformDiagnosticMetadata';
import { PrivacyConsentRepository } from '../repositories/PrivacyConsentRepository';
import { PrivacyConsentApplication } from './PrivacyConsentApplication';
import { ReadingRecordsApplication } from './ReadingRecordsApplication';

export interface ApplicationInitialization {
  reconciliation: ReconciliationReport;
}

export class ApplicationRuntime {
  readonly privacyConsent: PrivacyConsentApplication = new PrivacyConsentApplication(new PrivacyConsentRepository());
  readonly readerSettings: ReaderSettingsRepository = new ReaderSettingsRepository();
  readonly readerSessions: ReaderSessionService = readerSessionService;
  readonly libraryPresentation: LibraryPresentationApplication;
  readonly readerAppearance: ReaderAppearanceApplication;
  readonly bookmarks: BookmarkApplication;
  readonly textMarks: TextMarkApplication;
  readonly organization: LibraryOrganizationApplication;
  readonly readingRecords: ReadingRecordsApplication;
  private libraryRepository: LibraryRepository = new LibraryRepository();
  private encryptedBookmarks: EncryptedBookmarkStore = new EncryptedBookmarkStore();
  private libraryPresentationRepository: LibraryPresentationRepository = new LibraryPresentationRepository();
  private dictionaryProvider?: BundledDictionaryProvider;
  private dictionary?: DictionaryService;
  private libraryBoundary?: LibraryApplication;
  private diagnosticExport?: DiagnosticExportApplication;

  constructor() {
    this.libraryPresentation = new LibraryPresentationApplication(this.libraryPresentationRepository);
    this.readerAppearance = new ReaderAppearanceApplication(this.readerSettings, systemColorModeLifecycle);
    this.textMarks = new TextMarkApplication(this.libraryRepository, this.encryptedBookmarks);
    this.organization = new LibraryOrganizationApplication(this.libraryRepository);
    this.bookmarks = new BookmarkApplication(this.libraryRepository, this.encryptedBookmarks, this.textMarks);
    this.readingRecords = new ReadingRecordsApplication(this.bookmarks, this.textMarks);
  }

  async initialize(context: common.UIAbilityContext): Promise<ApplicationInitialization> {
    await this.libraryRepository.initialize(context);
    this.textMarks.initialize(context);
    if (await this.libraryRepository.bookmarkAuthority() === 'target' ||
      await this.libraryRepository.textRecordsEnabled()) {
      try {
        await this.encryptedBookmarks.openExisting(context);
        await this.libraryRepository.activateRangeRecords();
      }
      catch (_) { /* Record actions fail closed; library and progress remain available. */ }
    }
    this.readerSettings.initialize(context);
    this.libraryPresentationRepository.initialize(context);
    this.readerSessions.initialize(this.libraryRepository);
    this.diagnosticExport = new DiagnosticExportApplication(
      readerOpenDiagnostics,
      new PlatformDiagnosticMetadata(),
      new DiagnosticFileExport(new NativeDiagnosticSaveSurface(context), new NativeDiagnosticFileSurface()));
    const managedStore = new ManagedBookStore(context);
    const reconciliation = new LibraryReconciliationService(
      context, this.libraryRepository, managedStore, this.encryptedBookmarks, this.readerSettings);
    const library = new LibraryApplication(
      this.libraryRepository,
      new BookImportService(context, this.libraryRepository, managedStore, createProductionImportPolicy()),
      new BookDeletionService(context, this.libraryRepository, managedStore, this.encryptedBookmarks, this.readerSettings),
      reconciliation,
      managedStore);
    this.libraryBoundary = library;
    const report = await library.reconcile();
    const provider = new BundledDictionaryProvider(context);
    this.dictionaryProvider = provider;
    this.dictionary = new DictionaryService(provider);
    provider.initialize().catch((): void => {});
    return { reconciliation: report };
  }

  library(): LibraryApplication | undefined {
    return this.libraryBoundary;
  }

  dictionaryService(): DictionaryService | undefined {
    return this.dictionary;
  }

  diagnosticExporter(): DiagnosticExportApplication | undefined {
    return this.diagnosticExport;
  }

  dispose(): void {
    this.dictionary?.cancelPending();
    this.dictionaryProvider?.close().catch((): void => {});
    this.libraryRepository.close();
    this.encryptedBookmarks.close();
  }
}
