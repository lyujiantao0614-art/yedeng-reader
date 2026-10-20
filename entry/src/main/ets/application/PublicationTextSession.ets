import { SectionText, SectionTextProvider } from '../domain/SectionText';

// The application owns the lifetime; the EPUB adapter supplies bounded text,
// never Web controllers or provider protocols to consumers.
export class PublicationTextSession {
  private revision: number = 0;
  private sessionId: number = 0;
  private provider?: SectionTextProvider;
  private busy: boolean = false;
  bind(sessionId: number, provider: SectionTextProvider): void {
    this.revision++; this.sessionId = sessionId; this.provider = provider; this.busy = false;
  }
  close(sessionId: number): void {
    if (sessionId !== this.sessionId) return;
    this.revision++; this.provider = undefined;
  }
  async read(sessionId: number, index: number): Promise<SectionText> {
    if (sessionId !== this.sessionId || !this.provider || this.busy || !Number.isSafeInteger(index) || index < 0) {
      throw new Error('Publication text unavailable');
    }
    const revision = this.revision;
    this.busy = true;
    try {
      const result = await this.provider.read(index);
      if (revision !== this.revision) throw new Error('Obsolete publication text');
      return result;
    } finally { if (revision === this.revision) this.busy = false; }
  }
}
