import { describe, it, expect } from '@ohos/hypium';
import { DEFAULT_READER_SETTINGS, normalizeReaderSettings, ReadingLocation, WEB_READER_ENGINE_ID } from '../main/ets/domain/Models';
import {
  bytesToHex,
  classifyInspectionError,
  isMatchingRepairIdentity,
  resolveDisplayTitle
} from '../main/ets/services/BookImportService';
import { EpubInspectionError } from '../main/ets/services/EpubInspector';
import { filterAndSortLibrary, LibraryEntry } from '../main/ets/services/LibraryQueryService';
import { dictionaryPartOfSpeech, normalizeSelectedWord, regularLemmaCandidates } from '../main/ets/dictionary/DictionaryLookup';
import { AIProvider, AIProviderError } from '../main/ets/ai/AIProvider';
import {
  AIConnectionResult,
  AIProviderConfig,
  AIReadingRequest,
  AIReadingResponse
} from '../main/ets/ai/AIReadingModels';
import {
  AIReadingService,
  AIRequestIdSource,
  assembleProviderContext,
  buildReadingPrompt,
  providerContextLength
} from '../main/ets/ai/AIReadingService';
import { ReadingSelectionContext } from '../main/ets/reader/ReadingSelectionModels';
import {
  AI_PROVIDER_CREDENTIAL_REF,
  OPENAI_COMPATIBLE_PROVIDER_ID,
  createAIProviderConfig,
  validateCredentialInput
} from '../main/ets/ai/AIConfiguration';
import {
  MAX_AI_HTTP_RESPONSE_BYTES,
  buildChatCompletionBody,
  chatCompletionsUrl,
  classifyHttpStatus,
  parseChatCompletion
} from '../main/ets/ai/OpenAICompatibleProtocol';
import {
  LOCAL_EPUB_REQUEST_URL,
  classifyReaderRequest,
  shouldBlockReaderNavigation
} from '../main/ets/reader/ReaderNetworkPolicy';
import { AIReadingActionSession } from '../main/ets/ai/AIReadingActionSession';
import { AIRequestLifecycle } from '../main/ets/ai/AIRequestLifecycle';
import {
  MEDIUM_EPUB_MAX_BYTES,
  SMALL_EPUB_MAX_BYTES,
  classifyReaderOpenEpubSize,
  classifyReaderOpenRestoreDepth,
  isWebReaderOpenStage
} from '../main/ets/diagnostics/ReaderOpenDiagnosticsContract';
import { isValidLibraryOperationTransition } from '../main/ets/repositories/LibraryRepository';
import { isValidBookId, isValidUuid } from '../main/ets/services/ManagedBookStore';
import { ReaderSessionLifecycle } from '../main/ets/reader/ReaderSessionLifecycle';
import {
  ReaderApplicationLifecycle,
  ReaderApplicationLifecycleHandler
} from '../main/ets/reader/ReaderApplicationLifecycle';
import { ReaderSurfaceState } from '../main/ets/reader/ReaderSurfaceState';
import { ProductShellState } from '../main/ets/shell/ProductShellState';
import {
  ReaderThemePreference,
  SystemColorMode,
  normalizeReaderThemePreference,
  resolveReaderTheme
} from '../main/ets/domain/AppearancePolicy';
import { normalizeLibraryViewMode } from '../main/ets/domain/LibraryPresentation';
import { SystemColorModeLifecycle } from '../main/ets/reader/SystemColorModeLifecycle';

interface PendingAICompletion {
  request: AIReadingRequest;
  resolve: (response: AIReadingResponse) => void;
}

class SequenceRequestIdSource implements AIRequestIdSource {
  private index: number = 0;

  nextRequestId(): string {
    this.index += 1;
    return `request-${this.index}`;
  }
}

class DeferredFakeAIProvider implements AIProvider {
  readonly pending: PendingAICompletion[] = [];
  readonly cancelled: string[] = [];

  testConnection(config: AIProviderConfig): Promise<AIConnectionResult> {
    const result: AIConnectionResult = {
      ok: true,
      providerId: config.providerId,
      modelId: config.modelId
    };
    return Promise.resolve(result);
  }

  complete(request: AIReadingRequest): Promise<AIReadingResponse> {
    return new Promise<AIReadingResponse>((resolve): void => {
      this.pending.push({ request: request, resolve: resolve });
    });
  }

  cancel(requestId: string): void {
    this.cancelled.push(requestId);
  }

  succeed(index: number, text: string): void {
    const pending = this.pending[index];
    const response: AIReadingResponse = {
      requestId: pending.request.requestId,
      text: text,
      providerId: 'fake',
      modelId: 'fake-model'
    };
    pending.resolve(response);
  }

}

class RejectingFakeAIProvider implements AIProvider {
  testConnection(config: AIProviderConfig): Promise<AIConnectionResult> {
    const result: AIConnectionResult = {
      ok: true,
      providerId: config.providerId,
      modelId: config.modelId
    };
    return Promise.resolve(result);
  }

  complete(_: AIReadingRequest): Promise<AIReadingResponse> {
    return Promise.reject(new AIProviderError(
      'authentication', 'Rejected sk-private-fixture', false));
  }

  cancel(_: string): void {
  }
}

class CountingApplicationLifecycleHandler implements ReaderApplicationLifecycleHandler {
  count: number = 0;

  onBackground(): void {
    this.count += 1;
  }

  onForeground(): void {
    this.count += 10;
  }
}

function readingContext(kind: 'word' | 'passage', selectedText: string): ReadingSelectionContext {
  return {
    selectionToken: `token-${kind}`,
    kind: kind,
    selectedText: selectedText,
    bookTitle: 'Fixture Book',
    chapterTitle: 'Fixture Chapter',
    previousText: 'Previous paragraph.',
    currentText: 'Current paragraph with the selected text.',
    nextText: 'Next paragraph.'
  };
}

function entry(id: string, title: string, author: string, importedAt: number,
  lastOpenedAt?: number): LibraryEntry {
  return {
    book: {
      bookId: id, fileHash: id, title: title, author: author,
      epubRelativePath: `books/${id}/book.epub`, importedAt: importedAt,
      lastOpenedAt: lastOpenedAt, sourceState: 'available'
    },
    percentage: 0
  };
}

export default function localUnitTest() {
  describe('phase1aPureLogic', () => {
    it('encodesDigestBytesAsStableLowercaseHex', 0, () => {
      expect(bytesToHex(new Uint8Array([0, 1, 15, 16, 254, 255])))
        .assertEqual('00010f10feff');
    });

    it('searchesTitleAndAuthorWithoutCase', 0, () => {
      const values = [entry('a', 'The Left Hand', 'Ursula Le Guin', 1),
        entry('b', 'Piranesi', 'Susanna Clarke', 2)];
      expect(filterAndSortLibrary(values, '  le GUIN ', 'recent').length).assertEqual(1);
      expect(filterAndSortLibrary(values, 'PIRAN', 'recent')[0].book.bookId).assertEqual('b');
    });

    it('usesStableLibrarySortRules', 0, () => {
      const values = [entry('b', 'Beta', 'B', 200), entry('a', 'Alpha', 'A', 10, 30)];
      expect(filterAndSortLibrary(values.slice(), '', 'recent')[0].book.bookId).assertEqual('a');
      expect(filterAndSortLibrary(values.slice(), '', 'title')[0].book.bookId).assertEqual('a');
      expect(filterAndSortLibrary(values.slice(), '', 'imported')[0].book.bookId).assertEqual('b');
    });

    it('usesMetadataFallbackAndClassifiedErrors', 0, () => {
      expect(resolveDisplayTitle(undefined, 'fallback.epub')).assertEqual('fallback.epub');
      expect(resolveDisplayTitle('  A title  ', 'fallback.epub')).assertEqual('A title');
      expect(classifyInspectionError(new EpubInspectionError('encrypted', 'unsupported')))
        .assertEqual('encrypted');
      expect(classifyInspectionError(new EpubInspectionError('malformed', 'bad spine')))
        .assertEqual('malformed');
    });

    it('normalizesSettingsForSafePersistenceRoundTrip', 0, () => {
      const restored = normalizeReaderSettings({
        fontScale: 9, lineSpacing: 0, pageMarginVp: 24, theme: 'dark'
      });
      expect(restored.fontScale).assertEqual(1.6);
      expect(restored.lineSpacing).assertEqual(1.2);
      expect(restored.pageMarginVp).assertEqual(24);
      expect(restored.theme).assertEqual('dark');
    });

    it('serializesEngineAwareLocationAndKeepsDefaults', 0, () => {
      const location: ReadingLocation = {
        engine: WEB_READER_ENGINE_ID, locator: 'epubcfi(/6/2!/4/2/1:0)',
        percentage: 0.25, chapterId: 'chapter1.xhtml'
      };
      const restored = JSON.parse(JSON.stringify(location)) as ReadingLocation;
      expect(restored.engine).assertEqual(WEB_READER_ENGINE_ID);
      expect(restored.locator).assertEqual(location.locator);
      expect(DEFAULT_READER_SETTINGS.theme).assertEqual('light');
      expect(DEFAULT_READER_SETTINGS.pageMarginVp).assertEqual(20);
    });
  });

  describe('phase3Milestone0ReaderOpenDiagnosticsContract', () => {
    it('usesOnlyCoarseEpubSizeBucketsAtFixedBoundaries', 0, () => {
      expect(classifyReaderOpenEpubSize(undefined)).assertEqual('unknown');
      expect(classifyReaderOpenEpubSize(SMALL_EPUB_MAX_BYTES)).assertEqual('small');
      expect(classifyReaderOpenEpubSize(SMALL_EPUB_MAX_BYTES + 1)).assertEqual('medium');
      expect(classifyReaderOpenEpubSize(MEDIUM_EPUB_MAX_BYTES + 1)).assertEqual('large');
    });

    it('classifiesRestoreDepthWithoutExposingTheLocator', 0, () => {
      expect(classifyReaderOpenRestoreDepth(undefined)).assertEqual('start');
      expect(classifyReaderOpenRestoreDepth(0)).assertEqual('start');
      expect(classifyReaderOpenRestoreDepth(0.2)).assertEqual('shallow');
      expect(classifyReaderOpenRestoreDepth(0.8)).assertEqual('deep');
    });

    it('acceptsOnlyTheFixedWebReaderStageAllowlist', 0, () => {
      expect(isWebReaderOpenStage('epub_parsed')).assertEqual(true);
      expect(isWebReaderOpenStage('viewer_committed')).assertEqual(true);
      expect(isWebReaderOpenStage('locator')).assertEqual(false);
      expect(isWebReaderOpenStage('book-title')).assertEqual(false);
    });
  });

  describe('phase3Milestone1FoundationContracts', () => {
    it('acceptsOnlyValidOperationKindStatePairs', 0, () => {
      expect(isValidLibraryOperationTransition('import', 'preparing')).assertEqual(true);
      expect(isValidLibraryOperationTransition('repair', 'prepared')).assertEqual(true);
      expect(isValidLibraryOperationTransition('delete', 'requested')).assertEqual(true);
      expect(isValidLibraryOperationTransition('delete', 'files_removed')).assertEqual(true);
      expect(isValidLibraryOperationTransition('delete', 'prepared')).assertEqual(false);
      expect(isValidLibraryOperationTransition('import', 'files_removed')).assertEqual(false);
    });

    it('rejectsPathShapedBookIdsAndStagingTokens', 0, () => {
      expect(isValidBookId('a'.repeat(64))).assertEqual(true);
      expect(isValidBookId('A'.repeat(64))).assertEqual(false);
      expect(isValidBookId('../' + 'a'.repeat(61))).assertEqual(false);
      expect(isValidUuid('c0a80121-1234-4abc-8def-1234567890ab')).assertEqual(true);
      expect(isValidUuid('../c0a80121-1234-4abc-8def-1234567890ab')).assertEqual(false);
    });

    it('repairsOnlyTheExactByteIdentity', 0, () => {
      const expected = 'a'.repeat(64);
      expect(isMatchingRepairIdentity(expected, expected)).assertEqual(true);
      expect(isMatchingRepairIdentity(expected, 'b'.repeat(64))).assertEqual(false);
      expect(isMatchingRepairIdentity(expected, 'A'.repeat(64))).assertEqual(false);
    });

    it('rejectsLateAndIllegalReaderLifecycleTransitions', 0, () => {
      const lifecycle = new ReaderSessionLifecycle();
      expect(lifecycle.beginOpening(1)).assertEqual(true);
      expect(lifecycle.markReady(0)).assertEqual(false);
      expect(lifecycle.markReady(1)).assertEqual(true);
      expect(lifecycle.beginOpening(2)).assertEqual(true);
      expect(lifecycle.markReady(1)).assertEqual(false);
      expect(lifecycle.enterBackground(2)).assertEqual(true);
      expect(lifecycle.markReady(2)).assertEqual(true);
      expect(lifecycle.state()).assertEqual('background');
      expect(lifecycle.enterForeground(2)).assertEqual(true);
      expect(lifecycle.state()).assertEqual('ready');
      expect(lifecycle.markReady(2)).assertEqual(false);
      expect(lifecycle.beginClosing(2)).assertEqual(true);
      expect(lifecycle.finishClosing(2)).assertEqual(true);
      expect(lifecycle.state()).assertEqual('idle');

      const backDuringOpen = new ReaderSessionLifecycle();
      expect(backDuringOpen.beginOpening(10)).assertEqual(true);
      expect(backDuringOpen.beginClosing(10)).assertEqual(true);
      expect(backDuringOpen.markReady(10)).assertEqual(false);
      expect(backDuringOpen.finishClosing(10)).assertEqual(true);

      const rapidSwitch = new ReaderSessionLifecycle();
      expect(rapidSwitch.beginOpening(20)).assertEqual(true);
      expect(rapidSwitch.beginClosing(20)).assertEqual(true);
      expect(rapidSwitch.finishClosing(20)).assertEqual(true);
      expect(rapidSwitch.beginOpening(21)).assertEqual(true);
      expect(rapidSwitch.markReady(20)).assertEqual(false);
      expect(rapidSwitch.markReady(21)).assertEqual(true);
      expect(rapidSwitch.markError(20)).assertEqual(false);

      const deleteCurrent = new ReaderSessionLifecycle();
      expect(deleteCurrent.beginOpening(30)).assertEqual(true);
      expect(deleteCurrent.markReady(30)).assertEqual(true);
      expect(deleteCurrent.beginClosing(30)).assertEqual(true);
      expect(deleteCurrent.markError(30)).assertEqual(false);
      expect(deleteCurrent.finishClosing(30)).assertEqual(true);
    });
  });

  describe('phase3Milestone2AApplicationShellContracts', () => {
    it('navigatesBySemanticDestinationWithoutEncodingVisualControls', 0, () => {
      const shell = new ProductShellState();
      expect(shell.destination()).assertEqual('library');
      shell.navigate('reader');
      expect(shell.destination()).assertEqual('reader');
      expect(shell.handleBack()).assertEqual('library');
      shell.navigate('settings');
      expect(shell.handleBack()).assertEqual('library');
      expect(shell.handleBack()).assertUndefined();
    });

    it('normalizesNarrowPresentationPreferences', 0, () => {
      expect(normalizeLibraryViewMode('list')).assertEqual('list');
      expect(normalizeLibraryViewMode('grid')).assertEqual('grid');
      expect(normalizeLibraryViewMode('title')).assertEqual('grid');
      expect(normalizeReaderThemePreference('system')).assertEqual('system');
      expect(normalizeReaderThemePreference('eye-comfort')).assertEqual('eye-comfort');
      expect(normalizeReaderThemePreference('unknown')).assertEqual('system');
      expect(normalizeReaderThemePreference(undefined)).assertEqual('system');
    });

    it('resolvesPersistentReaderThemesFromCurrentSystemMode', 0, () => {
      const preferences: ReaderThemePreference[] = ['system', 'light', 'dark', 'eye-comfort'];
      const systemModes: SystemColorMode[] = ['light', 'dark'];
      preferences.forEach((preference: ReaderThemePreference): void => {
        systemModes.forEach((systemMode: SystemColorMode): void => {
          const expectedTheme = preference === 'system' ? systemMode : preference;
          expect(resolveReaderTheme(preference, systemMode)).assertEqual(expectedTheme);
        });
      });
    });

    it('deliversOnlyChangedSystemColorModesToCurrentSubscribers', 0, () => {
      const lifecycle = new SystemColorModeLifecycle();
      let first = '';
      let second = '';
      const unsubscribe = lifecycle.subscribe((mode): void => { first += mode; });
      lifecycle.handleMode('dark');
      lifecycle.subscribe((mode): void => { second += mode; });
      lifecycle.handleMode('dark');
      unsubscribe();
      lifecycle.handleMode('light');
      expect(first).assertEqual('lightdark');
      expect(second).assertEqual('darklight');
    });

    it('keepsExactlyOneLocalReaderSurface', 0, () => {
      const surfaces = new ReaderSurfaceState();
      surfaces.show('dictionary');
      expect(surfaces.surface()).assertEqual('dictionary');
      surfaces.show('passage');
      expect(surfaces.surface()).assertEqual('passage');
      surfaces.show('note-editor');
      expect(surfaces.surface()).assertEqual('note-editor');
      surfaces.dismiss();
      expect(surfaces.surface()).assertEqual('none');
    });

    it('distributesLifecycleWithoutRetainingAnUnsubscribedHandler', 0, () => {
      const lifecycle = new ReaderApplicationLifecycle();
      const firstHandler = new CountingApplicationLifecycleHandler();
      const secondHandler = new CountingApplicationLifecycleHandler();
      const unsubscribeFirst = lifecycle.subscribe(firstHandler);
      lifecycle.subscribe(secondHandler);
      lifecycle.handleBackground();
      unsubscribeFirst();
      lifecycle.handleForeground();
      expect(firstHandler.count).assertEqual(1);
      expect(secondHandler.count).assertEqual(11);
    });
  });

  describe('phase1bDictionaryPureLogic', () => {
    it('normalizesOneWordButPreservesTheSelectedSurface', 0, () => {
      const value = normalizeSelectedWord('  “Running,”  ');
      expect(value?.selectedForm).assertEqual('“Running,”');
      expect(value?.normalizedTerm).assertEqual('running');
      expect(normalizeSelectedWord("reader's")?.normalizedTerm).assertEqual('reader');
    });

    it('rejectsMultiWordAndNonLatinSelection', 0, () => {
      expect(normalizeSelectedWord('silver compass')).assertUndefined();
      expect(normalizeSelectedWord('算法')).assertUndefined();
      expect(normalizeSelectedWord('')).assertUndefined();
    });

    it('generatesBoundedExistingHeadwordCandidatesInStableOrder', 0, () => {
      const running = regularLemmaCandidates('running');
      expect(running[0]).assertEqual('runn');
      expect(running[1]).assertEqual('runne');
      expect(running[2]).assertEqual('run');
      expect(regularLemmaCandidates('stories')[0]).assertEqual('story');
    });

    it('mapsOnlyObservedOmwPartsOfSpeech', 0, () => {
      expect(dictionaryPartOfSpeech('n')).assertEqual('noun');
      expect(dictionaryPartOfSpeech('v')).assertEqual('verb');
      expect(dictionaryPartOfSpeech('a')).assertEqual('adjective');
      expect(dictionaryPartOfSpeech('r')).assertEqual('adverb');
      expect(dictionaryPartOfSpeech('u')).assertUndefined();
    });
  });

  describe('phase2Milestone2ProviderNeutralCore', () => {
    it('keepsExactUnicodeSelectionAndDeterministicallyBoundsNearbyContext', 0, () => {
      const source: ReadingSelectionContext = {
        selectionToken: 'unicode-boundary',
        kind: 'passage',
        selectedText: '🌟'.repeat(2000),
        bookTitle: 'B'.repeat(256),
        chapterTitle: 'C'.repeat(256),
        previousText: 'P'.repeat(2000),
        currentText: 'M'.repeat(2000),
        nextText: 'N'.repeat(2000)
      };
      const accepted = assembleProviderContext(source);
      expect(accepted.selectedText.length).assertEqual(4000);
      expect(accepted.currentText?.length).assertEqual(2000);
      expect(accepted.previousText?.length).assertEqual(744);
      expect(accepted.nextText?.length).assertEqual(744);
      expect(providerContextLength(accepted)).assertEqual(8000);
    });

    it('omitsEmptyOptionalFieldsAndBuildsSpoilerBoundedPrompts', 0, () => {
      const source: ReadingSelectionContext = {
        selectionToken: 'empty-optionals',
        kind: 'word',
        selectedText: 'bank',
        bookTitle: '   ',
        currentText: 'She sat on the river bank.'
      };
      const accepted = assembleProviderContext(source);
      expect(accepted.bookTitle).assertUndefined();
      const prompt = buildReadingPrompt('explain-word-in-context', accepted);
      expect(prompt.system.includes('Do not reveal plot')).assertEqual(true);
      expect(prompt.system.includes('preserve important English terms')).assertEqual(true);
      expect(prompt.user.includes('selected word sense')).assertEqual(true);
      const customized = buildReadingPrompt('explain-word-in-context', accepted, undefined,
        'Use short bullet points.');
      expect(customized.system).assertEqual('Use short bullet points.');
      expect(customized.user.includes('Selected text:\nbank')).assertEqual(true);
    });

    it('rejectsWrongTargetKindsAndOverlongQuestionsBeforeProviderUse', 0, async () => {
      const provider = new DeferredFakeAIProvider();
      const service = new AIReadingService(provider, new SequenceRequestIdSource());
      const wrongKind = await service.complete('translate-context', readingContext('word', 'bank'));
      expect(wrongKind.error?.code).assertEqual('invalid-input');
      const longQuestion = await service.complete('ask-reading-context',
        readingContext('passage', 'A bounded passage.'), 'Q'.repeat(501));
      expect(longQuestion.error?.code).assertEqual('invalid-input');
      const longSelection = await service.complete('translate-context',
        readingContext('passage', 'S'.repeat(4001)));
      expect(longSelection.error?.code).assertEqual('invalid-input');
      const longParagraph = readingContext('passage', 'A bounded passage.');
      longParagraph.previousText = 'P'.repeat(2001);
      const invalidParagraph = await service.complete('translate-context', longParagraph);
      expect(invalidParagraph.error?.code).assertEqual('invalid-input');
      expect(provider.pending.length).assertEqual(0);
    });

    it('excludesReaderIdentityAndLocatorFromProviderRequests', 0, async () => {
      const provider = new DeferredFakeAIProvider();
      const service = new AIReadingService(provider, new SequenceRequestIdSource());
      const completion = service.complete('translate-context', readingContext('passage', 'Silver compass.'));
      expect(provider.pending.length).assertEqual(1);
      const serialized = JSON.stringify(provider.pending[0].request);
      expect(serialized.includes('selectionToken')).assertEqual(false);
      expect(serialized.includes('locator')).assertEqual(false);
      expect(serialized.includes('bookId')).assertEqual(false);
      provider.succeed(0, '银色罗盘。');
      const result = await completion;
      expect(result.response?.text).assertEqual('银色罗盘。');
    });

    it('mapsProviderErrorsWithoutEchoingSecrets', 0, async () => {
      const provider = new RejectingFakeAIProvider();
      const service = new AIReadingService(provider, new SequenceRequestIdSource());
      const result = await service.complete('explain-word-in-context', readingContext('word', 'bank'));
      expect(result.error?.code).assertEqual('authentication');
      expect(result.error?.message).assertEqual('AI provider rejected the credential');
      expect(result.error?.message.includes('sk-private-fixture')).assertEqual(false);
    });

    it('cancelsEarlierWorkAndSuppressesOutOfOrderResponses', 0, async () => {
      const provider = new DeferredFakeAIProvider();
      const service = new AIReadingService(provider, new SequenceRequestIdSource());
      const first = service.complete('translate-context', readingContext('passage', 'First passage.'));
      const second = service.complete('translate-context', readingContext('passage', 'Second passage.'));
      expect(provider.cancelled[0]).assertEqual('request-1');
      provider.succeed(1, '第二段。');
      provider.succeed(0, '第一段。');
      const secondResult = await second;
      const firstResult = await first;
      expect(secondResult.response?.requestId).assertEqual('request-2');
      expect(firstResult.error?.code).assertEqual('stale-response');
    });

    it('returnsCancelledAfterExplicitCancellationEvenIfTransportCompletes', 0, async () => {
      const provider = new DeferredFakeAIProvider();
      const service = new AIReadingService(provider, new SequenceRequestIdSource());
      const completion = service.complete('ask-reading-context',
        readingContext('passage', 'A passage.'), 'What does this imply?');
      service.cancelActive();
      provider.succeed(0, 'A late answer.');
      const result = await completion;
      expect(provider.cancelled[0]).assertEqual('request-1');
      expect(result.error?.code).assertEqual('cancelled');
    });
  });

  describe('phase2Milestone3ByokConfiguration', () => {
    it('normalizesOnlyNonSecretProviderConfiguration', 0, () => {
      const config = createAIProviderConfig('  https://example.com/v1/  ', 'fixture-model');
      expect(config.providerId).assertEqual(OPENAI_COMPATIBLE_PROVIDER_ID);
      expect(config.baseUrl).assertEqual('https://example.com/v1');
      expect(config.modelId).assertEqual('fixture-model');
      expect(config.credentialRef).assertEqual(AI_PROVIDER_CREDENTIAL_REF);
      expect(JSON.stringify(config).includes('apiKey')).assertEqual(false);
      const openRouter = createAIProviderConfig(
        'https://openrouter.ai/api/v1', 'deepseek/deepseek-v3.2');
      expect(openRouter.baseUrl).assertEqual('https://openrouter.ai/api/v1');
      expect(openRouter.modelId).assertEqual('deepseek/deepseek-v3.2');
    });

    it('rejectsUnsafeOrMalformedProviderEndpoints', 0, () => {
      const invalidValues = [
        'http://example.com/v1',
        'https://user:password@example.com/v1',
        'https://example.com/v1#fragment',
        'https://example.com/v1?key=value',
        'https://example.com\\evil/v1',
        'https://example..com/v1',
        'https://example.com:70000/v1',
        'https:///missing-host',
        `https://example.com/${'x'.repeat(2048)}`
      ];
      let rejected = 0;
      invalidValues.forEach((value: string): void => {
        try {
          createAIProviderConfig(value, 'fixture-model');
        } catch (_) {
          rejected += 1;
        }
      });
      expect(rejected).assertEqual(invalidValues.length);
    });

    it('boundsModelOptionsAndCredentialInputWithoutChangingSecrets', 0, () => {
      const synthetic = 'm3-synthetic-secret-A';
      expect(validateCredentialInput(synthetic)).assertEqual(synthetic);
      let rejectedOptions = false;
      let rejectedCredential = false;
      try {
        createAIProviderConfig('https://example.com/v1', 'fixture-model', { maxOutputTokens: 8193 });
      } catch (_) {
        rejectedOptions = true;
      }
      try {
        validateCredentialInput(' synthetic-secret ');
      } catch (_) {
        rejectedCredential = true;
      }
      expect(rejectedOptions).assertEqual(true);
      expect(rejectedCredential).assertEqual(true);
    });
  });

  describe('phase2Milestone4NativeProviderAndReaderIsolation', () => {
    it('buildsTheOpenAICompatibleEndpointAndSyntheticConnectionPayload', 0, () => {
      expect(chatCompletionsUrl('https://openrouter.ai/api/v1'))
        .assertEqual('https://openrouter.ai/api/v1/chat/completions');
      const body = buildChatCompletionBody('fixture/model',
        'Synthetic system instruction.', 'Reply with exactly OK.', { maxOutputTokens: 8 });
      expect(body.includes('fixture/model')).assertEqual(true);
      expect(body.includes('Reply with exactly OK.')).assertEqual(true);
      expect(body.includes('selectedText')).assertEqual(false);
      expect(body.includes('bookId')).assertEqual(false);
      expect(body.includes('locator')).assertEqual(false);
      expect(body.includes('stream')).assertEqual(true);
    });

    it('parsesOnlyBoundedChatCompletionText', 0, () => {
      const parsed = parseChatCompletion(
        '{"model":"fixture/model","choices":[{"message":{"content":"OK"}}]}');
      expect(parsed.text).assertEqual('OK');
      expect(parsed.modelId).assertEqual('fixture/model');
      let rejectedMissing = false;
      let rejectedOversized = false;
      try {
        parseChatCompletion('{"choices":[]}');
      } catch (_) {
        rejectedMissing = true;
      }
      try {
        parseChatCompletion('x'.repeat(MAX_AI_HTTP_RESPONSE_BYTES + 1));
      } catch (_) {
        rejectedOversized = true;
      }
      expect(rejectedMissing).assertEqual(true);
      expect(rejectedOversized).assertEqual(true);
    });

    it('classifiesSafeProviderErrorsWithoutDependingOnResponseBodies', 0, () => {
      expect(classifyHttpStatus(200)).assertEqual('success');
      expect(classifyHttpStatus(401)).assertEqual('authentication');
      expect(classifyHttpStatus(402)).assertEqual('authentication');
      expect(classifyHttpStatus(404)).assertEqual('endpoint-model');
      expect(classifyHttpStatus(429)).assertEqual('rate-limit');
      expect(classifyHttpStatus(504)).assertEqual('timeout');
      expect(classifyHttpStatus(503)).assertEqual('network');
    });

    it('allowsOnlyTheInterceptedLocalBookAndBlocksReaderNetworkSchemes', 0, () => {
      expect(classifyReaderRequest('GET', LOCAL_EPUB_REQUEST_URL)).assertEqual('local-book');
      expect(classifyReaderRequest('POST', LOCAL_EPUB_REQUEST_URL)).assertEqual('block-network');
      expect(classifyReaderRequest('GET', 'https://external.invalid/image.png'))
        .assertEqual('block-network');
      expect(classifyReaderRequest('GET', 'ws://external.invalid/socket'))
        .assertEqual('block-network');
      expect(classifyReaderRequest('GET', 'resource://rawfile/web-reader/index.html'))
        .assertEqual('allow-local');
      expect(shouldBlockReaderNavigation('https://external.invalid/chapter')).assertEqual(true);
      expect(shouldBlockReaderNavigation(LOCAL_EPUB_REQUEST_URL)).assertEqual(true);
      expect(shouldBlockReaderNavigation('about:blank')).assertEqual(false);
    });
  });

  describe('phase2Milestone5WordContextExplanation', () => {
    it('preparesSanitizedPrivacySummaryWithoutSending', 0, () => {
      const provider = new DeferredFakeAIProvider();
      const config = createAIProviderConfig(
        'https://openrouter.ai/api/v1', 'fixture/word-model');
      const session = new AIReadingActionSession(
        new AIReadingService(provider, new SequenceRequestIdSource()), config);
      const prepared = session.prepare('explain-word-in-context', readingContext('word', 'bank'));
      expect(prepared.error).assertUndefined();
      expect(prepared.summary?.selectedText).assertEqual('bank');
      expect(prepared.summary?.modelId).assertEqual('fixture/word-model');
      expect((prepared.summary?.nearbyContextLength ?? 0) > 0).assertEqual(true);
      const serialized = JSON.stringify(prepared.summary);
      expect(serialized.includes('credentialRef')).assertEqual(false);
      expect(serialized.includes('selectionToken')).assertEqual(false);
      expect(serialized.includes('locator')).assertEqual(false);
      expect(provider.pending.length).assertEqual(0);
    });

    it('rejectsMissingConfigurationAndPassageWithoutProviderUse', 0, () => {
      const missing = new AIReadingActionSession();
      expect(missing.prepare('explain-word-in-context', readingContext('word', 'bank')).error?.code)
        .assertEqual('configuration');

      const provider = new DeferredFakeAIProvider();
      const configured = new AIReadingActionSession(
        new AIReadingService(provider, new SequenceRequestIdSource()),
        createAIProviderConfig('https://example.com/v1', 'fixture-model'));
      expect(configured.prepare('explain-word-in-context', readingContext('passage', 'river bank')).error?.code)
        .assertEqual('invalid-input');
      expect(provider.pending.length).assertEqual(0);
    });

    it('sendsOnlyAfterExplicitSendAndReturnsTheBoundedAnswer', 0, async () => {
      const provider = new DeferredFakeAIProvider();
      const session = new AIReadingActionSession(
        new AIReadingService(provider, new SequenceRequestIdSource()),
        createAIProviderConfig('https://example.com/v1', 'fixture-model'));
      session.prepare('explain-word-in-context', readingContext('word', 'bank'));
      expect(provider.pending.length).assertEqual(0);
      const completion = session.send();
      expect(provider.pending.length).assertEqual(1);
      expect(provider.pending[0].request.action).assertEqual('explain-word-in-context');
      expect(provider.pending[0].request.targetKind).assertEqual('word');
      provider.succeed(0, '这里的 bank 指河岸，而不是银行。');
      expect((await completion)?.response?.text).assertEqual('这里的 bank 指河岸，而不是银行。');
    });

    it('suppressesLateCompletionAfterSessionCancellation', 0, async () => {
      const provider = new DeferredFakeAIProvider();
      const session = new AIReadingActionSession(
        new AIReadingService(provider, new SequenceRequestIdSource()),
        createAIProviderConfig('https://example.com/v1', 'fixture-model'));
      session.prepare('explain-word-in-context', readingContext('word', 'bank'));
      const completion = session.send();
      session.cancel();
      provider.succeed(0, 'A late answer.');
      expect(await completion).assertUndefined();
      expect(provider.cancelled[0]).assertEqual('request-1');
    });

    it('deliversBackgroundCancellationOnlyWhileBound', 0, () => {
      const lifecycle = new AIRequestLifecycle();
      let count = 0;
      lifecycle.bindBackground((): void => { count += 1; });
      lifecycle.handleBackground();
      lifecycle.unbindBackground();
      lifecycle.handleBackground();
      expect(count).assertEqual(1);
    });
  });

  describe('phase2Milestone6ContextualTranslation', () => {
    it('preparesPassagePrivacyWithoutSendingAndKeepsTheAcceptedSelection', 0, () => {
      const provider = new DeferredFakeAIProvider();
      const session = new AIReadingActionSession(
        new AIReadingService(provider, new SequenceRequestIdSource()),
        createAIProviderConfig('https://example.com/v1', 'fixture-translation-model'));
      const prepared = session.prepare('translate-context', readingContext('passage', 'He sat on the bank.'));
      expect(prepared.error).assertUndefined();
      expect(prepared.summary?.action).assertEqual('translate-context');
      expect(prepared.summary?.targetKind).assertEqual('passage');
      expect(prepared.summary?.selectedText).assertEqual('He sat on the bank.');
      expect(provider.pending.length).assertEqual(0);
      const serialized = JSON.stringify(prepared.summary);
      expect(serialized.includes('credentialRef')).assertEqual(false);
      expect(serialized.includes('selectionToken')).assertEqual(false);
      expect(serialized.includes('locator')).assertEqual(false);
    });

    it('sendsOnlyTheExplicitPassageTranslationWithNearbyContext', 0, async () => {
      const provider = new DeferredFakeAIProvider();
      const session = new AIReadingActionSession(
        new AIReadingService(provider, new SequenceRequestIdSource()),
        createAIProviderConfig('https://example.com/v1', 'fixture-translation-model'));
      const context = readingContext('passage', 'He sat on the bank.');
      context.previousText = 'The river was running high after the rain.';
      context.currentText = 'He sat on the bank and watched the water.';
      context.nextText = 'A small boat passed quietly.';
      session.prepare('translate-context', context);
      const completion = session.send();
      expect(provider.pending.length).assertEqual(1);
      expect(provider.pending[0].request.action).assertEqual('translate-context');
      expect(provider.pending[0].request.targetKind).assertEqual('passage');
      expect(provider.pending[0].request.prompt.user.includes('Translate only the selected passage')).assertEqual(true);
      expect(provider.pending[0].request.prompt.user.includes('The river was running high')).assertEqual(true);
      expect(provider.pending[0].request.prompt.user.includes('Selected text:\nHe sat on the bank.')).assertEqual(true);
      const serialized = JSON.stringify(provider.pending[0].request);
      expect(serialized.includes('selectionToken')).assertEqual(false);
      expect(serialized.includes('locator')).assertEqual(false);
      expect(serialized.includes('bookId')).assertEqual(false);
      provider.succeed(0, '他坐在河岸上。');
      expect((await completion)?.response?.text).assertEqual('他坐在河岸上。');
    });

    it('rejectsWordKindForTranslationBeforeProviderUse', 0, () => {
      const provider = new DeferredFakeAIProvider();
      const session = new AIReadingActionSession(
        new AIReadingService(provider, new SequenceRequestIdSource()),
        createAIProviderConfig('https://example.com/v1', 'fixture-translation-model'));
      const prepared = session.prepare('translate-context', readingContext('word', 'bank'));
      expect(prepared.error?.code).assertEqual('invalid-input');
      expect(provider.pending.length).assertEqual(0);
    });
  });
}
