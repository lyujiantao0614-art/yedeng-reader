export type ReaderLifecycleState = 'idle' | 'opening' | 'ready' | 'closing' | 'background' | 'error';

export class ReaderSessionLifecycle {
  private currentState: ReaderLifecycleState = 'idle';
  private activeSessionId: number = 0;
  private stateBeforeBackground: ReaderLifecycleState = 'idle';

  state(): ReaderLifecycleState {
    return this.currentState;
  }

  sessionId(): number {
    return this.activeSessionId;
  }

  beginOpening(sessionId: number): boolean {
    if (sessionId <= this.activeSessionId ||
      (this.currentState !== 'idle' && this.currentState !== 'ready' && this.currentState !== 'error')) return false;
    this.activeSessionId = sessionId;
    this.currentState = 'opening';
    return true;
  }

  markReady(sessionId: number): boolean {
    if (sessionId !== this.activeSessionId) return false;
    if (this.currentState === 'background' && this.stateBeforeBackground === 'opening') {
      this.stateBeforeBackground = 'ready';
      return true;
    }
    if (this.currentState !== 'opening') return false;
    this.currentState = 'ready';
    return true;
  }

  markError(sessionId: number): boolean {
    if (sessionId !== this.activeSessionId ||
      (this.currentState !== 'opening' && this.currentState !== 'ready' && this.currentState !== 'background')) {
      return false;
    }
    this.currentState = 'error';
    return true;
  }

  enterBackground(sessionId: number): boolean {
    if (sessionId !== this.activeSessionId ||
      (this.currentState !== 'opening' && this.currentState !== 'ready')) return false;
    this.stateBeforeBackground = this.currentState;
    this.currentState = 'background';
    return true;
  }

  enterForeground(sessionId: number): boolean {
    if (sessionId !== this.activeSessionId || this.currentState !== 'background') return false;
    this.currentState = this.stateBeforeBackground === 'opening' ? 'opening' : 'ready';
    return true;
  }

  beginClosing(sessionId: number): boolean {
    if (sessionId !== this.activeSessionId || this.currentState === 'idle' || this.currentState === 'closing') {
      return false;
    }
    this.currentState = 'closing';
    return true;
  }

  finishClosing(sessionId: number): boolean {
    if (sessionId !== this.activeSessionId || this.currentState !== 'closing') return false;
    this.currentState = 'idle';
    return true;
  }

  accepts(sessionId: number): boolean {
    return sessionId === this.activeSessionId &&
      (this.currentState === 'opening' || this.currentState === 'ready');
  }
}
