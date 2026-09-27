export interface ReaderSurfaceState {
  index: number;
  href: string;
  base: string;
  complete: boolean;
  cfiRoundTrip: boolean;
  originalCfiMatches: boolean;
  baseMatches: boolean;
  units: number;
  viewport: number;
  unit: number;
}

export interface ReaderPreparationJob {
  slot: number;
  index: number;
  version: number;
  priority: number;
  initialAtEnd: boolean;
  resolve: () => void;
  reject: (error: Error) => void;
}

export class ReaderSurfaceBridge {
  onCatalog: (raw: string) => boolean = (): boolean => false;
  onSelection: (slot: number, selected: boolean) => void = (): void => {};
  onBlock: (slot: number, blocked: boolean) => void = (): void => {};
  onTap: (slot: number, region: number) => void = (): void => {};
  onMarkTap: (slot: number, raw: string) => void = (): void => {};
  onSelectionEvent: (slot: number, raw: string) => void = (): void => {};
  onSelectionAdjusting: (slot: number) => void = (): void => {};
  onLink: (slot: number, raw: string) => void = (): void => {};
  onSourceDone: (token: number, ready: boolean) => void = (): void => {};
  onPacketDone: (token: number, ready: boolean) => void = (): void => {};
  onLoadDone: (slot: number, token: number, ready: boolean) => void = (): void => {};
  onLayoutDone: (slot: number, token: number, ready: boolean) => void = (): void => {};
  private stagedSlot: number = -1;
  private stagedToken: number = -1;
  private stagedPacket: string = '';

  catalog(raw: string): boolean { return this.onCatalog(raw); }
  selection(slot: number, selected: boolean): void { this.onSelection(slot, selected); }
  block(slot: number, blocked: boolean): void { this.onBlock(slot, blocked); }
  tap(slot: number, region: number): void { this.onTap(slot, region); }
  markTap(slot: number, raw: string): void { this.onMarkTap(slot, raw); }
  selectionEvent(slot: number, raw: string): void { this.onSelectionEvent(slot, raw); }
  adjusting(slot: number): void { this.onSelectionAdjusting(slot); }
  link(slot: number, raw: string): void { this.onLink(slot, raw); }
  sourceDone(token: number, ready: boolean): void { this.onSourceDone(token, ready); }
  packetDone(token: number, ready: boolean): void { this.onPacketDone(token, ready); }
  loadDone(slot: number, token: number, ready: boolean): void { this.onLoadDone(slot, token, ready); }
  layoutDone(slot: number, token: number, ready: boolean): void { this.onLayoutDone(slot, token, ready); }

  stagePacket(slot: number, token: number, packet: string): void {
    this.stagedSlot = slot;
    this.stagedToken = token;
    this.stagedPacket = packet;
  }

  takePacket(slot: number, token: number): string {
    // ArkWeb invokes this callback on the app thread. Throwing here is an
    // uncaught native-to-JS exception and terminates the entire app.
    if (slot !== this.stagedSlot || token !== this.stagedToken || this.stagedPacket.length === 0) {
      return 'null';
    }
    const packet = this.stagedPacket;
    this.clearPacket();
    return packet;
  }

  clearPacket(token?: number): void {
    if (token !== undefined && token !== this.stagedToken) return;
    this.stagedSlot = -1;
    this.stagedToken = -1;
    this.stagedPacket = '';
  }
}
