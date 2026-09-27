export interface ReaderApplicationLifecycleHandler {
  onBackground(): void;
  onForeground(): void;
}

export class ReaderApplicationLifecycle {
  private handlers: ReaderApplicationLifecycleHandler[] = [];

  subscribe(handler: ReaderApplicationLifecycleHandler): () => void {
    if (!this.handlers.includes(handler)) this.handlers.push(handler);
    return (): void => { this.unsubscribe(handler); };
  }

  unsubscribe(handler: ReaderApplicationLifecycleHandler): void {
    this.handlers = this.handlers.filter((candidate) => candidate !== handler);
  }

  handleBackground(): void {
    for (const handler of this.handlers.slice()) handler.onBackground();
  }

  handleForeground(): void {
    for (const handler of this.handlers.slice()) handler.onForeground();
  }
}

export const readerApplicationLifecycle: ReaderApplicationLifecycle = new ReaderApplicationLifecycle();
