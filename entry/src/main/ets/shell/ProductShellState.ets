export type ProductDestination = 'library' | 'mine' | 'reader' | 'settings' | 'records';

export class ProductShellState {
  private current: ProductDestination = 'library';
  private origin: ProductDestination = 'library';

  destination(): ProductDestination {
    return this.current;
  }

  navigate(destination: ProductDestination): void {
    if (destination === 'settings') this.origin = this.current;
    this.current = destination;
  }

  handleBack(): ProductDestination | undefined {
    if (this.current === 'records') { this.current = 'mine'; return this.current; }
    if (this.current === 'settings' || this.current === 'reader') {
      this.current = this.current === 'settings' ? this.origin : 'library';
      return this.current;
    }
    return undefined;
  }
}
